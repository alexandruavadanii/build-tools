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

set -o pipefail
set -e

LIBDIR="$(dirname $(readlink -f ${BASH_SOURCE[0]}))"

PUBLISH_RESULTS="${PUBLISH_RESULTS:-false}"
VIRT_CUSTOMIZE_MEM="${VIRT_CUSTOMIZE_MEM:-}"
VIRT_CUSTOMIZE_SMP="${VIRT_CUSTOMIZE_SMP:-}"
PARALLEL_BUILD_TIMEOUT="${PARALLEL_BUILD_TIMEOUT:-0}"
ENABLE_GOLDEN_IMAGE_ROOT_PASSWORD="${ENABLE_GOLDEN_IMAGE_ROOT_PASSWORD:-true}"
GOLDEN_BASE_IMAGE_TAR_URL=${GOLDEN_BASE_IMAGE_TAR_URL:-}
GOLDEN_BASE_IMAGE_FETCH_USER=${GOLDEN_BASE_IMAGE_FETCH_USER:-}
GOLDEN_BASE_IMAGE_FETCH_PASSWORD=${GOLDEN_BASE_IMAGE_FETCH_PASSWORD:-}

WORK=$(dirname $(dirname $LIBDIR))
RPM_BUILDER=$(find $WORK -maxdepth 2 -type d -name rpmbuilder)

WORKTMP=$WORK/tmp
WORKLOGS=$WORKTMP/logs
DURATION_LOG=$WORKLOGS/durations.log
MANIFEST_PATH=$WORK/.repo/manifests
BUILD_CONFIG_INI=$WORK/.repo/manifests/build_config.ini
GOLDEN_IMAGE_NAME=guest-image.img
TMP_GOLDEN_IMAGE=$WORKTMP/$GOLDEN_IMAGE_NAME

WORKRESULTS=$WORK/results
REPO_FILES=$WORKRESULTS/repo_files
REPO_DIR=$WORKRESULTS/repo
SRC_REPO_DIR=$WORKRESULTS/src_repo
RPMLISTS=$WORKRESULTS/rpmlists
CHECKSUM_DIR=$WORKRESULTS/bin_checksum
RESULT_IMAGES_DIR=$WORKRESULTS/images
RPM_BUILDER_SETTINGS=$WORKTMP/mocksettings/mock.cfg

function _read_build_config()
{
  local config_ini=$BUILD_CONFIG_INI
  if [[ -f "$1" ]] && [[ $1 == *.ini ]]; then
    config_ini=$1
    shift
  fi
  PYTHONPATH=$LIBDIR $LIBDIR/tools/script/read_build_config.py $config_ini $@
}

function _read_manifest_vars()
{
  PRODUCT_RELEASE_BUILD_ID="${BUILD_NUMBER:?0}"
  PRODUCT_RELEASE_LABEL="$(_read_build_config DEFAULT product_release_label)"
}

function _initialize_work_dirs()
{
  rm -rf $WORKRESULTS
  mkdir -p $WORKRESULTS $REPO_FILES $REPO_DIR $RPMLISTS $CHECKSUM_DIR
  # dont clear tmp, can be used for caching
  mkdir -p $WORKTMP
  rm -rf $WORKLOGS
  mkdir -p $WORKLOGS
}

function _log()
{
  echo "$(date) $@"
}

function _info()
{
  _log INFO: $@
}

function _header()
{
  _info "##################################################################"
  _info "# $@"
  _info "##################################################################"
}


function _divider()
{
  _info "------------------------------------------------------------------"
}


function _step()
{
  _header "STEP START: $@"
}


function _abort()
{
  _header "ERROR: $@"
  exit 1
}


function _success()
{
  _header "STEP OK: $@"
}


function _run_cmd()
{
  _info "[cmd-start]: $@"
  stamp_start=$(date +%s)
  time $@ 2>&1 || _abort "Command failed: $@"
  stamp_end=$(date +%s)
  echo "$((stamp_end - stamp_start)) $@" >> $DURATION_LOG.unsorted
  sort -nr $DURATION_LOG.unsorted > $DURATION_LOG
  _log "[cmd-end]: $@"
}


function _run_cmd_as_step()
{
  if [ $# -eq 1 -a -f $1 ]; then
    step="$(basename $1)"
  else
    step="$@"
  fi
  _step $step
  _run_cmd $@
  _success $step
}


function _add_rpms_to_repo()
{
  local repo_dir=$1
  local rpm_dir=$2
  mkdir -p $repo_dir
  cp -f $(repomanage --keep=1 --new $rpm_dir) $repo_dir/
}

function _create_localrepo()
{
  pushd $REPO_DIR
  _run_cmd createrepo --workers=8 --update .
  popd
  pushd $SRC_REPO_DIR
  _run_cmd createrepo --workers=8 --update .
  popd
}

function _add_rpms_to_repos_from_workdir()
{
  _add_rpms_to_repo $REPO_DIR $1/buildrepository/mock/rpm
  _add_rpms_to_repo $SRC_REPO_DIR $1/buildrepository/mock/srpm
  #find $1/ -name '*.tar.gz' | xargs rm -f
  true
}

function _publish_results()
{
  local from=$1
  local to=$2
  mkdir -p $(dirname $to)
  mv -f $from $to
}

function _publish_image()
{
  _publish_results $1 $2
  _create_checksum $2
}

function _create_checksum()
{
  _create_md5_checksum $1
  _create_sha256_checksum $1
}

function _create_sha256_checksum()
{
  pushd $(dirname $1)
    time sha256sum $(basename $1) > $(basename $1).sha256
  popd
}

function _create_md5_checksum()
{
  pushd $(dirname $1)
    time md5sum $(basename $1) > $(basename $1).md5
  popd
}

function _is_true()
{
  # e.g. for Jenkins boolean parameters
  [ "$1" == "true" ]
}

function _join_array()
{
  local IFS="$1"
  shift
  echo "$*"
}

function _get_package_list()
{
  PYTHONPATH=$LIBDIR $LIBDIR/tools/script/read_package_config.py $@
}

function _load_docker_image()
{
  local docker_image=$1
  local docker_image_url="$(_read_build_config DEFAULT docker_images)/${docker_image}.tar"
  if docker inspect ${docker_image} &> /dev/null; then
    echo "Using already built ${docker_image} image"
  else
    echo "Loading ${docker_image} image"
    curl -L $docker_image_url | docker load
  fi
}
