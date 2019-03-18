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
_read_manifest_vars

tmp=$WORKTMP/install_cd
iso_build_dir=$tmp/build

input_image="$WORKTMP/goldenimage/${GOLDEN_IMAGE_NAME}"
output_image_path="$1"
[[ $output_image_path =~ ^/ ]] || output_image_path=$(pwd)/$output_image_path
output_bootcd_path="$2"
[[ $output_bootcd_path =~ ^/ ]] || output_bootcd_path=$(pwd)/$output_bootcd_path
mkdir -p $tmp
rm -rf $iso_build_dir
mkdir -p $iso_build_dir

reposnap_base=$(_read_build_config DEFAULT centos_reposnap_base)
release_version=$PRODUCT_RELEASE_LABEL
reposnap_base_dir="${reposnap_base}/os/x86_64/"
iso_image_label=$(_read_build_config DEFAULT iso_image_label)
cd_efi_dir="${reposnap_base_dir}/EFI"
cd_images_dir="${reposnap_base_dir}/images"
cd_isolinux_dir="${reposnap_base_dir}/isolinux"

remove_extra_slashes_from_url() {
  echo $1 | sed -re 's#([^:])//+#\1/#g'
}

get_nexus() {
 $scriptdir/nexus3_dl.sh \
    $nexus_url \
    $(basename $nexus_reposnaps) \
    ${reposnap_base#$nexus_reposnaps/}/os/x86_64 $@
}

wget_dir() {
  local url=$1
  echo $url | grep -q /$ || _abort "wget path '$url' must end with slash for recursive wget"
  # if any extra slashes within path, it messes up the --cut-dirs count
  url=$(remove_extra_slashes_from_url $url)
  # count cut length in case url depth changes
  cut_dirs=$(echo $url | sed -re 's|.*://[^/]+/(.+)|\1|' -e 's|/$||' | grep -o / | wc -l)
  wget -N -r --no-host-directories --no-verbose --cut-dirs=${cut_dirs} --reject index.html* --no-parent $url
}

pushd $iso_build_dir

# Get files needed for generating CD image.
if echo $reposnap_base_dir | grep -E "https?://nexus3"; then
  nexus_url=$(_read_build_config DEFAULT nexus_url)
  nexus_reposnaps=$(_read_build_config DEFAULT nexus_reposnaps)
  get_nexus "EFI/BOOT" "EFI/BOOT/fonts"
  get_nexus "images:*efiboot.img" "images/pxeboot"
  get_nexus "isolinux"
else
  wget_dir ${cd_efi_dir}/
  wget_dir ${cd_images_dir}/
  rm -rf images/boot.iso
  sync
  wget_dir ${cd_isolinux_dir}/
fi
chmod +w -R isolinux/ EFI/ images/

if [ -e $scriptdir/isolinux/isolinux.cfg ]; then
    cp $scriptdir/isolinux/isolinux.cfg isolinux/isolinux.cfg
else
    sed -i "s/^timeout.*/timeout 100/" isolinux/isolinux.cfg
    sed -i "s/^ -  Press.*/Beginning the cloud installation process/" isolinux/boot.msg
    sed -i "s/^#menu hidden/menu hidden/" isolinux/isolinux.cfg
    sed -i "s/menu default//" isolinux/isolinux.cfg
    sed -i "/^label linux/amenu default" isolinux/isolinux.cfg
    sed -i "/append initrd/ s/$/ console=tty0 console=ttyS1,115200/" isolinux/isolinux.cfg
fi
cp -f $scriptdir/akraino_splash.png isolinux/splash.png

popd

pushd $tmp

 # Copy latest kernel and initrd-provisioning from boot dir
virt-copy-out -a $input_image /boot/ ./
chmod u+w boot/
rm -f $iso_build_dir/isolinux/vmlinuz $iso_build_dir/isolinux/initrd.img
KVER=`ls -lrt boot/vmlinuz-* |grep -v rescue |tail -n1 |awk -F 'boot/vmlinuz-' '{print $2}'`
cp -fp boot/vmlinuz-${KVER} $iso_build_dir/isolinux/vmlinuz
cp -fp boot/initrd-provisioning.img $iso_build_dir/isolinux/initrd.img
rm -rf boot/

echo "Generating boot iso"
_run_cmd genisoimage  -U -r -v -T -J -joliet-long \
  -V "${release_version}" -A "${release_version}" -P ${iso_image_label} \
  -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 \
  -boot-info-table -eltorito-alt-boot -e images/efiboot.img -no-emul-boot \
  -o boot.iso $iso_build_dir
_publish_image $tmp/boot.iso $output_bootcd_path

cp -f ${input_image} $iso_build_dir/

# Keep the placeholder
mkdir -p $iso_build_dir/rpms

echo "Generating product iso"
_run_cmd genisoimage  -U -r -v -T -J -joliet-long \
  -V "${release_version}" -A "${release_version}" -P ${iso_image_label} \
  -b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 \
  -boot-info-table -eltorito-alt-boot -e images/efiboot.img -no-emul-boot \
  -o release.iso $iso_build_dir
_run_cmd isohybrid $tmp/release.iso
_publish_image $tmp/release.iso $output_image_path

echo "Clean up to preserve workspace footprint"
rm -f $iso_build_dir/$(basename ${input_image})
rm -rf $iso_build_dir/rpms

popd