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

input_image=$(readlink -f ${1:-$WORKTMP/goldenimage/$GOLDEN_IMAGE_NAME})
output_image_path=${2:-$RESULT_IMAGES_DIR/install.iso}
output_bootcd_path=${3:-$RESULT_IMAGES_DIR/bootcd.iso}
mkdir -p $tmp
rm -rf $iso_build_dir
mkdir -p $iso_build_dir

iso_arch="$(uname -m)"
reposnap_base=$(_read_build_config DEFAULT centos_reposnap)
release_version=$PRODUCT_RELEASE_LABEL
reposnap_base_dir="${reposnap_base}/os/${iso_arch}/"
iso_image_label=$(_read_build_config DEFAULT iso_image_label)
cd_efi_dir="${reposnap_base_dir}/EFI"
cd_images_dir="${reposnap_base_dir}/images"
cd_isolinux_dir="${reposnap_base_dir}/isolinux"

remove_extra_slashes_from_url() {
  echo $1 | sed -re 's#([^:])//+#\1/#g'
}

wget_dir() {
  local url=$1
  echo $url | grep -q /$ || _abort "wget path '$url' must end with slash for recursive wget"
  # if any extra slashes within path, it messes up the --cut-dirs count
  url=$(remove_extra_slashes_from_url $url)
  # count cut length in case url depth changes
  cut_dirs=$(echo $url | sed -re 's|.*://[^/]+/(.+)|\1|' -e 's|/$||' | grep -o / | wc -l)
  wget -N -r \
    --no-host-directories \
    --no-verbose \
    --cut-dirs=${cut_dirs} \
    --reject index.html* \
    --no-parent \
    --execute robots=off \
    $url
}

pushd $iso_build_dir

# Get files needed for generating CD image.
wget_dir ${cd_efi_dir}/
wget_dir ${cd_images_dir}/
rm -f images/boot.iso
sync
chmod +w -R EFI/ images/
# AArch64 does not support PC-BIOS, so skip all isolinux processing
if [ "${iso_arch}" != 'aarch64' ]; then
    wget_dir ${cd_isolinux_dir}/
    chmod +w -R isolinux/

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
fi

# Update grub.cfg for EFI booting, similar to isolinux
sed -i '/menuentry/{N;N;N;q}' EFI/BOOT/grub.cfg
sed -i -e 's|Install CentOS 7|Beginning the cloud installation process|' \
       -e '/vmlinuz/ s/$/ console=tty0 console=ttyS1,115200 console=ttyAMA0,115200/' \
    EFI/BOOT/grub.cfg

popd

pushd $tmp

 # Copy latest kernel and initrd-provisioning from boot dir
if [ "${iso_arch}" != 'aarch64' ]; then
    qemu-img convert $input_image guest-image.raw
    myloop=$(sudo losetup -fP --show guest-image.raw)
    mkdir mnt
    sudo mount -o loop ${myloop}p1 mnt/
    sudo rsync -avA mnt/boot .
    sudo chown -R $(id -u):$(id -g) boot
    sudo umount mnt
    sudo losetup -d ${myloop}
    rm -f guest-image.raw
else
    export LIBGUESTFS_BACKEND=direct
    virt-copy-out -a $input_image /boot/ ./
fi

chmod u+w boot/
KVER=`ls -lrt boot/vmlinuz-* |grep -v rescue |tail -n1 |awk -F 'boot/vmlinuz-' '{print $2}'`
if [ "${iso_arch}" != 'aarch64' ]; then
    rm -f $iso_build_dir/isolinux/vmlinuz $iso_build_dir/isolinux/initrd.img
    cp -fp boot/vmlinuz-${KVER} $iso_build_dir/isolinux/vmlinuz
    cp -fp boot/initrd-provisioning.img $iso_build_dir/isolinux/initrd.img
fi
rm -f $iso_build_dir/images/pxeboot/vmlinuz $iso_build_dir/images/pxeboot/initrd.img
cp -fp boot/vmlinuz-${KVER} $iso_build_dir/images/pxeboot/vmlinuz
cp -fp boot/initrd-provisioning.img $iso_build_dir/images/pxeboot/initrd.img
rm -rf boot/

echo "Generating boot iso"
if [ "${iso_arch}" != 'aarch64' ]; then
    bios_specific_args="-b isolinux/isolinux.bin -c isolinux/boot.cat \
                        -no-emul-boot -boot-load-size 4 -boot-info-table"
fi
genisoimage  -U -r -v -T -J -joliet-long \
  -V "${release_version}" -A "${release_version}" -P ${iso_image_label} \
  ${bios_specific_args:-} \
  -eltorito-alt-boot -e images/efiboot.img -no-emul-boot \
  -o boot.iso $iso_build_dir
_publish_image $tmp/boot.iso $output_bootcd_path

cp -f ${input_image} $iso_build_dir/

# Keep the placeholder
mkdir -p $iso_build_dir/rpms

echo "Generating product iso"
genisoimage  -U -r -v -T -J -joliet-long \
  -V "${release_version}" -A "${release_version}" -P ${iso_image_label} \
  ${bios_specific_args:-} \
  -eltorito-alt-boot -e images/efiboot.img -no-emul-boot \
  -o release.iso $iso_build_dir
[ "${iso_arch}" = 'aarch64' ] || isohybrid $tmp/release.iso
_publish_image $tmp/release.iso $output_image_path

echo "Clean up to preserve workspace footprint"
rm -f $iso_build_dir/$(basename ${input_image})
rm -rf $iso_build_dir/rpms

popd
