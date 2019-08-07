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

set -e

scriptdir="$(dirname $(readlink -f ${BASH_SOURCE[0]}))"
source $scriptdir/lib.sh
_read_manifest_vars

config_ini=${1:-$BUILD_CONFIG_INI}
output_repo_files_dir=${2:-$REPO_FILES}
output_mock_dir=${2:-$output_repo_files_dir}
[ -f "$config_ini" ] || _abort "Config INI '$config_ini' not found"

# Create .repo files
$LIBDIR/build_step_create_yum_repo_files.sh $config_ini $output_repo_files_dir

# Create mock config
mkdir -p $output_mock_dir
cp $LIBDIR/mock/logging.ini $output_mock_dir/
cp $LIBDIR/mock/site-defaults.cfg $output_mock_dir/
mock_cfg=$output_mock_dir/mock.cfg
sed -e "/#REPOSITORIES#/r $output_repo_files_dir/repositories.repo" $LIBDIR/mock/mock.cfg.template > $mock_cfg
sed -i \
  -e "s/#RPM_ARCH#/\"$(uname -m)\"/" \
  -e "s/#RPM_PACKAGER#/\"$(_read_build_config $config_ini rpm packager)\"/" \
  -e "s/#RPM_VENDOR#/\"$(_read_build_config $config_ini rpm vendor)\"/" \
  -e "s/#RPM_LICENSE#/\"$(_read_build_config $config_ini rpm license)\"/" \
  -e "s/#RPM_RELEASE_ID#/\"$(_read_build_config $config_ini rpm release_id)\"/" \
  -e "s/#PRODUCT_RELEASE_BUILD_ID#/\"$PRODUCT_RELEASE_BUILD_ID\"/" \
  -e "s/#PRODUCT_RELEASE_LABEL#/\"$PRODUCT_RELEASE_LABEL\"/" \
  $mock_cfg

docker_sock=/var/run/docker.sock
if [ -S "$docker_sock" ]; then
  sed -i "/#ADDITIONAL_CONFIG_OPTS#/a config_opts['plugin_conf']['bind_mount_opts']['dirs'].append(('$docker_sock', '$docker_sock'))" $mock_cfg
fi
if [ -n "$DOCKER_HOST" ]; then
  sed -i "/#ADDITIONAL_CONFIG_OPTS#/a config_opts['environment']['DOCKER_HOST'] = '${DOCKER_HOST}:2375'" $mock_cfg
fi

# HACK ??
# include kernels in order for yum development group to install
sed -i -e 's/exclude=kernel/#exclude=kernel/' $mock_cfg

echo "Wrote mock configuration to: $output_mock_dir"
