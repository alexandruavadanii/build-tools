#!/bin/bash
# Copyright 2019 Nokia
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -x
set -e
set -o pipefail

scriptdir="$(dirname $(readlink -f ${BASH_SOURCE[0]}))"
source $scriptdir/lib.sh

BASE_IMAGE_URL=${BASE_IMAGE_URL:-$(_read_build_config DEFAULT base_image)}
CENTOS_SNAP=${CENTOS_SNAP:-$(_read_build_config DEFAULT centos_reposnap)}

BASE_IMAGE_NAME=`echo $BASE_IMAGE_URL | awk -F "/" '{print $NF}'`
BASE_IMAGE_SIZE="8GiB"
[ "$(uname -m)" != aarch64 ] || EXTRA_ELEMENTS="block-device-efi"

wget_args=""
[ -n "$GOLDEN_BASE_IMAGE_FETCH_USER" ] && wget_args="$wget_args --http-user=$GOLDEN_BASE_IMAGE_FETCH_USER"
[ -n "$GOLDEN_BASE_IMAGE_FETCH_PASSWORD" ] && wget_args="$wget_args --http-password=$GOLDEN_BASE_IMAGE_FETCH_PASSWORD"

fetch_image() {
    sourceurl=$1
    echo "Download $sourceurl to $WORKTMP/base-img"
    mkdir -pv $WORKTMP/base-img
    pushd $WORKTMP/base-img
    wget --no-check-certificate --no-verbose -N \
    --auth-no-challenge $wget_args \
    $sourceurl
    popd
}

fetch_image $BASE_IMAGE_URL
cp $MANIFEST_PATH/packages.yaml $scriptdir/dib_elements/myproduct/package-installs.yaml

DIB_DEBUG_TRACE=1 \
  FS_TYPE=xfs \
  PACKAGES_TO_INSTALL="$(_get_package_list install)" \
  PACKAGES_TO_UNINSTALL="$(_get_package_list uninstall)" \
  DIB_RPMLISTS=$RPMLISTS \
  DIB_CHECKSUM=$CHECKSUM_DIR \
  DIB_LOCAL_REPO=$REPO_DIR \
  DIB_DISTRIBUTION_MIRROR=$CENTOS_SNAP \
  DIB_YUM_REPO_CONF="${REPO_FILES}/repositories.repo ${REPO_FILES}/localrepo.repo" \
  DIB_LOCAL_IMAGE=$WORKTMP/base-img/$BASE_IMAGE_NAME \
  ELEMENTS_PATH=$scriptdir/dib_elements/ \
  /usr/bin/disk-image-create --root-label img-rootfs --image-size $BASE_IMAGE_SIZE vm centos7 selinux-permissive myproduct ${EXTRA_ELEMENTS:-} -o $TMP_GOLDEN_IMAGE

rm -rf $WORKTMP/base-img
