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

usage() {
    echo "Usage: $0 -m <manifest-dir> -w <work-dir> [-r <rpmbuilder-dir> -p <rpm-create-search-dir>]"
    exit 1
}

rpm_search_paths=""
while getopts "m:w:p:r:" OPT; do
    case $OPT in
    m)
        export MANIFEST_PATH=$(readlink -f $OPTARG)
        ;;
    w)
        export WORK=$OPTARG
        ;;
    r)
        export RPMBUILDER_PATH=$(readlink -f $OPTARG)
        ;;
    p)
        rpm_search_paths+=" $OPTARG"
        ;;
    *)
        usage
        ;;
    esac
done

[ -z "$MANIFEST_PATH" ] && usage
[ -z "$WORK" ] && usage
[ -n "$rpm_search_paths" -a -z "$RPMBUILDER_PATH" ] && usage
shift "$((OPTIND-1))"
[ "$#" -ne 0 ] && usage

scriptdir="$(dirname $(readlink -f ${BASH_SOURCE[0]}))"
source $scriptdir/lib.sh

_initialize_work_dirs

dib_patch="$scriptdir/docker-context/Dockerfile-dib.$(uname -m).patch"
if [ -e "${dib_patch}" ]; then patch "$scriptdir/docker-context/Dockerfile-dib" "${dib_patch}"; fi

docker build -f $scriptdir/docker-context/Dockerfile-dib -t dib $scriptdir/docker-context
docker build -f $scriptdir/docker-context/Dockerfile-buildtools -t buildtools $scriptdir/docker-context

# Create manifest RPM
$LIBDIR/create_manifest_rpm.sh

# Create RPMs
if [ -n "$rpm_search_paths" ]; then
    $LIBDIR/build_rpms.sh $rpm_search_paths
fi

# Create repo config
$LIBDIR/build_step_create_yum_repo_files.sh

# QCOW
$LIBDIR/build_step_golden_image.sh
sha1short=$(grep -v product-manifest $RPMLISTS/rpmlist | sha1sum | cut -c-8)

# ISO images
$LIBDIR/build_step_create_install_cd.sh

echo "=== SUCCESS ==="
echo "Build results are in $WORKRESULTS"
echo "Installed RPMS checksum: ${sha1short} (this will change if list of installed RPMs changes)"
