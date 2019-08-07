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

set -ex

scriptdir="$(dirname $(readlink -f ${BASH_SOURCE[0]}))"
source $scriptdir/lib.sh

docker_image=buildtools
_load_docker_image $docker_image

function _resolve_abs_path() {
  if ! echo $1 | grep -q "^/"; then
    echo $(pwd)/$1
  else
    echo $1
  fi
}

input_dir=$(_resolve_abs_path ${1:?ERROR, please give input dir as argument})
output_dir=$(_resolve_abs_path ${2:?ERROR, please give output dir as argument})
shift; shift

# Run!
input_mp=/input
output_mp=/output
docker run \
  --rm \
  -e PYTHONPATH=/work \
  -e BUILD_URL -e JENKINS_USERNAME -e JENKINS_TOKEN -e WORK \
  -v $scriptdir:/work \
  -v $input_dir:$input_mp \
  -v $output_dir:$output_mp \
  -w /work \
  $docker_image \
  python tools/script/create_rpm_data.py \
    --build-config-path $input_mp/build_config.ini \
    --yum-info-path $input_mp/yum_info_installed \
    --rpm-info-path $input_mp/rpm_info_installed \
    --crypto-info-path $input_mp/crypto_rpms.json \
    --boms-path $input_mp/boms \
    --output-json $output_mp/rpmdata.json \
    --output-csv $output_mp/rpmdata.csv \
    --output-ms-csv $output_mp/rpmdata-ms.csv \
    --output-rpmlist $output_mp/rpmlist \
    $*

docker run \
  --rm \
  -e PYTHONPATH=/work \
  -v $scriptdir:/work \
  -v $output_dir:$output_mp \
  -w /work \
  $docker_image \
  python tools/script/process_rpmdata.py \
    --rpmdata-path $output_mp/rpmdata.json \
    --output-components $output_mp/components.json \
    --output-components-csv $output_mp/components-ms.csv \

