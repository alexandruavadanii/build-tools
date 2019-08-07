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

scriptdir="$(dirname $(readlink -f ${BASH_SOURCE[0]}))"
source $scriptdir/lib.sh

output_image_path=${1:-$WORKTMP/goldenimage/$GOLDEN_IMAGE_NAME}

docker_dib_image=dib
_load_docker_image $docker_dib_image

docker run \
  --rm \
  --privileged \
  -v /dev:/dev \
  -v $WORK:/work \
  -e WORK=/work \
  -v $MANIFEST_PATH:/manifest \
  -e MANIFEST_PATH=/manifest \
  -v $scriptdir:/tools \
  $docker_dib_image \
  /tools/create_golden_image.sh

mkdir -p $(dirname $output_image_path)
mv -f ${TMP_GOLDEN_IMAGE}.qcow2 $output_image_path

input_dir=$WORKTMP/rpmdata
mkdir -p $input_dir
cp -r \
  $BUILD_CONFIG_INI $RPMLISTS/rpm_info_installed $RPMLISTS/yum_info_installed $RPMLISTS/crypto_rpms.json $RPMLISTS/boms \
  $input_dir

$LIBDIR/create_rpmdata_in_docker.sh \
  $input_dir \
  $RPMLISTS \
  -v

