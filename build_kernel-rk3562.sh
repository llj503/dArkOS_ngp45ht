#!/bin/bash
#
# Kernel Build and Installation for RK3562 (RG52 Mini / RG43H Pro)
#
# Builds the kernel and device tree from source (kernel_rk3562/), and
# installs BSP components (firmware, bootloader) from the EmuELEC BSP
# extract. Mali GPU libraries are handled by build_deps.sh.
#
# Kernel source required at: ${KERNEL_SRC_PATH}
#   - Must have .config already prepared (use ${UNIT}_defconfig)
#   - DTS source: arch/arm64/boot/dts/rockchip/rk3562-{rg52mini,rg43h}.dts
#   - Shared DTSI: arch/arm64/boot/dts/rockchip/rk3562-darkos.dtsi
#
# BSP components required in ${BSP_PATH}:
#   - librga/ (BSP librga.so.2.1.0 + headers for RGA3 ABI)
#   - mali/libmali-hook.so.1.9.0 (optional - Mali hook library)
#   - firmware/ (WiFi, Bluetooth, etc.)
#   - uboot.img (optional - U-Boot FIT image)
#   - bootloader_area.img (raw bootloader including idbloader)
#

# Kernel source tree lives alongside the dArkOS build directory
KERNEL_SRC_PATH="${PWD}/kernel_rk3562"

# Device tree is built from DTS source in the kernel tree.
# DTS source files: arch/arm64/boot/dts/rockchip/rk3562-{rg52mini,rg43h}.dts
# Shared base:      arch/arm64/boot/dts/rockchip/rk3562-darkos.dtsi
DTB_FILE="${KERNEL_SRC_PATH}/arch/arm64/boot/dts/rockchip/${UNIT_DTB}.dtb"

echo "Building and installing kernel for RK3562..."

# Verify kernel source exists
if [ ! -d "${KERNEL_SRC_PATH}" ]; then
  echo "ERROR: Kernel source not found at ${KERNEL_SRC_PATH}"
  exit 1
fi

# Verify BSP path exists
if [ ! -d "${BSP_PATH}" ]; then
  echo "ERROR: BSP_PATH (${BSP_PATH}) not found!"
  echo "Please extract EmuELEC SYSTEM first using unsquashfs"
  exit 1
fi

# Extract compressed BSP Mali tarballs if not already extracted
if [ ! -d "${BSP_PATH}/mali" ] && [ -f "${BSP_PATH}/mali.tar.gz" ]; then
  echo "Extracting Mali 64-bit libraries..."
  tar xzf "${BSP_PATH}/mali.tar.gz" -C "${BSP_PATH}"
fi
if [ ! -d "${BSP_PATH}/mali32" ] && [ -f "${BSP_PATH}/mali32.tar.gz" ]; then
  echo "Extracting Mali 32-bit libraries..."
  tar xzf "${BSP_PATH}/mali32.tar.gz" -C "${BSP_PATH}"
fi

# Verify required BSP components
# Mali GPU blob (g29p1) is installed by build_deps.sh from BSP/mali*.tar.gz
# Only the DTB and firmware are required from BSP

# Boot logo. U-Boot draws nothing on this device: the device tree it runs with
# is the Rockchip evaluation-board stub, with no dsi, panel, vop or route nodes,
# so logo.bmp in the resource partition and logo.bmp on the FAT partition were
# both tried and both did nothing. The first thing that lights the panel is the
# kernel, so the logo comes from CONFIG_LOGO and fbcon draws it as soon as the
# framebuffer is up.
#
# The artwork is the vendor's, taken from the EmuELEC boot partition, already
# rotated counter-clockwise to 1280x720 so that fbcon=rotate:1 turns it back
# upright. It is stored gzipped because pnmtologo only accepts text PNM, which
# is 8.3 MB uncompressed and 81 KB packed.
LOGO_SRC="${BSP_PATH}/logo_linux_clut224.ppm.gz"
LOGO_DST="${KERNEL_SRC_PATH}/drivers/video/logo/logo_linux_clut224.ppm"
if [ -f "${LOGO_SRC}" ]; then
  echo "Installing boot logo..."
  gzip -dc "${LOGO_SRC}" > "${LOGO_DST}"
else
  echo "WARNING: ${LOGO_SRC} missing - the build will show the stock penguin"
fi

# Ensure the kernel .config exists and is not older than the defconfig.
#
# This used to be "if [ ! -f .config ]", which generated the config once and
# never again, so every edit to ${UNIT}_defconfig was ignored by every later
# build - silently, because the kernel still builds fine with the old config.
# That is how CONFIG_LOGO, CONFIG_CRYPTO_LZ4 and CONFIG_ZRAM_WRITEBACK were all
# committed, built, and absent from the 2026-09-16 image: its .config was three
# days older than the defconfig it was supposed to come from.
KERNEL_DEFCONFIG="${KERNEL_SRC_PATH}/arch/arm64/configs/${UNIT}_defconfig"
if [ ! -f "${KERNEL_SRC_PATH}/.config" ]; then
  echo "Generating kernel .config from ${UNIT}_defconfig..."
  make -C "${KERNEL_SRC_PATH}" ${UNIT}_defconfig
elif [ "${KERNEL_DEFCONFIG}" -nt "${KERNEL_SRC_PATH}/.config" ]; then
  echo "${UNIT}_defconfig is newer than .config - regenerating."
  echo "Any hand-made menuconfig changes will be lost; put them in the"
  echo "defconfig if they are meant to survive."
  make -C "${KERNEL_SRC_PATH}" ${UNIT}_defconfig
fi

# Build kernel Image and device tree
echo "Building kernel Image and DTB..."
make -C "${KERNEL_SRC_PATH}" -j$(nproc) Image rockchip/${UNIT_DTB}.dtb
if [ $? -ne 0 ]; then
  echo "ERROR: Kernel build failed"
  exit 1
fi

# Verify DTB was built
if [ ! -f "${DTB_FILE}" ]; then
  echo "ERROR: DTB not found at ${DTB_FILE}"
  exit 1
fi

# Get kernel version from the build system (not strings, which also matches
# the "Linux version %s" format string in the kernel binary)
KERNEL_VERSION=$(make -C "${KERNEL_SRC_PATH}" -s kernelrelease)
echo "Built kernel version: ${KERNEL_VERSION}"

# Build kernel modules
echo "Building kernel modules..."
make -C "${KERNEL_SRC_PATH}" -j$(nproc) modules
# Module build failures are non-fatal — we have BSP modules as fallback

# Mount boot partition
mountpoint=mnt/boot
mkdir -p ${mountpoint}
sudo mount ${LOOP_DEV}p3 ${mountpoint}

# Copy compiled kernel Image and patched DTB to boot partition
echo "Copying kernel and DTB..."
sudo cp "${KERNEL_SRC_PATH}/arch/arm64/boot/Image" ${mountpoint}/
sudo cp "${DTB_FILE}" ${mountpoint}/${UNIT_DTB}.dtb

# Artwork for U-Boot: the splash it shows at power-on and the charge
# animation. Both are read off this partition as ordinary files, because the
# resource partition is empty on this device.
#
# The BMPs must be 24-bit and uncompressed - the vendor's own frames are 8-bit
# RLE and this U-Boot will not draw them. logo.bmp is 720x1280, the panel's
# native portrait orientation; the charge frames are 220x110, centred.
#
# These are matched to the RG52 Mini bootloader and are copied for every unit.
# The RG43 Pro still runs the vendor U-Boot (BSP/uboot-rg43h.img, 2017.09 on
# the rk3562-evb tree), which has no panel nodes and draws nothing either way,
# so the change is believed to be moot there - but it is untested on that
# device. Its original 8-bit frames are one command away if that turns out to
# matter: git show 7e96820:BSP/battery_0.bmp > BSP/battery_0.bmp
echo "Copying U-Boot artwork..."
sudo cp ${BSP_PATH}/battery_*.bmp ${mountpoint}/ 2>/dev/null || true
if [ -f "${BSP_PATH}/logo.bmp" ]; then
  sudo cp ${BSP_PATH}/logo.bmp ${mountpoint}/
else
  echo "WARNING: ${BSP_PATH}/logo.bmp missing - U-Boot will show no splash"
fi

# Never ship logo_kernel.bmp. U-Boot hands that one to the kernel to keep
# displaying during boot, and on this device the handover blanks the panel:
# boot proceeds normally and the screen stays black once the system reaches
# the display. Without it the kernel brings the display up itself.
sudo rm -f ${mountpoint}/logo_kernel.bmp

# Install kernel modules from source build
echo "Installing kernel modules..."
sudo make -C "${KERNEL_SRC_PATH}" INSTALL_MOD_PATH="${PWD}/Arkbuild" modules_install

# Copy firmware blobs (follow symlinks, ignore dangling ones)
echo "Installing firmware..."
sudo mkdir -p Arkbuild/lib/firmware/
if [ -d "${BSP_PATH}/firmware" ]; then
  # Use rsync to handle symlinks gracefully
  sudo rsync -aL --ignore-errors ${BSP_PATH}/firmware/ Arkbuild/lib/firmware/ 2>/dev/null || \
    sudo cp -rL ${BSP_PATH}/firmware/* Arkbuild/lib/firmware/ 2>/dev/null || true
fi

# Mali GPU libraries are installed by build_deps.sh (g29p1 64-bit from BSP, g13p0
# 32-bit from core_builds). Install the 64-bit libmali-hook from BSP if available.
sudo mkdir -p Arkbuild/usr/lib/aarch64-linux-gnu/
sudo cp ${BSP_PATH}/mali/libmali-hook.so.1.9.0 Arkbuild/usr/lib/aarch64-linux-gnu/ 2>/dev/null || true
(
  cd Arkbuild/usr/lib/aarch64-linux-gnu
  sudo ln -sf libmali-hook.so.1.9.0 libmali-hook.so.1 2>/dev/null || true
  sudo ln -sf libmali-hook.so.1 libmali-hook.so 2>/dev/null || true
)

# Run ldconfig to update library cache
sudo chroot Arkbuild/ ldconfig -X

# Create kernel config for initramfs-tools
echo "Creating kernel config for initramfs-tools..."
sudo cp "${KERNEL_SRC_PATH}/.config" Arkbuild/boot/config-${KERNEL_VERSION}

# Create uInitrd
echo "Creating uInitrd..."
call_chroot "depmod ${KERNEL_VERSION}; update-initramfs -c -k ${KERNEL_VERSION}"
sudo cp Arkbuild/boot/initrd.img-${KERNEL_VERSION} ${mountpoint}/initrd.img

if ! command -v mkimage &> /dev/null; then
  install_host_package u-boot-tools uboot-tools
fi

# Update uInitrd to force booting from mmcblk1p4 (SD card rootfs)
# Use subshell to preserve cwd
(
  mkdir -p initrd
  sudo mv ${mountpoint}/initrd.img initrd/.
  cd initrd
  zstd -d -c initrd.img | cpio -idmv
  rm -f initrd.img
  sed -i '/local dev_id\=/c\\tlocal dev_id\=\"/dev/mmcblk1p4\"' scripts/local

  # Add regulatory.db for WiFi
  mkdir -p lib/firmware
  wget -t 3 -T 60 https://github.com/CaffeeLake/wireless-regdb/raw/refs/heads/master/regulatory.db -O lib/firmware/regulatory.db 2>/dev/null || true

  # Fix: fsck hook fails to detect root fstype during chroot build because
  # /dev/mmcblk1p4 doesn't exist, so it skips copying fsck/logsave entirely.
  # The initramfs scripts/functions still calls logsave unconditionally, and
  # the missing binary causes exit code 127 -> panic at boot.
  for bin in /sbin/fsck /sbin/logsave /sbin/fsck.btrfs; do
    src="../../Arkbuild${bin}"
    if [ -f "$src" ]; then
      cp "$src" ".${bin}"
      # Copy required shared libraries
      for lib in $(ldd "$src" 2>/dev/null | grep -o '/lib[^ ]*'); do
        mkdir -p ".$(dirname "$lib")"
        cp -n "$lib" ".$lib" 2>/dev/null || true
      done
    fi
  done

  find . | cpio -H newc -o | gzip -c > ../uInitrd
  sudo mv ../uInitrd ../${mountpoint}/uInitrd
  cd ..
  rm -rf initrd
)
sudo rm -f ${mountpoint}/initrd.img

# Flash bootloader components
echo "Flashing bootloader components..."

# Flash the idbloader (first 8MB contains idbloader at sector 64)
if [ -f "${BSP_PATH}/bootloader_area.img" ]; then
  echo "Flashing bootloader area (idbloader)..."
  # Only flash the idbloader portion (sectors 64-16383)
  sudo dd if=${BSP_PATH}/bootloader_area.img of=$LOOP_DEV bs=$SECTOR_SIZE skip=64 seek=64 count=16320 conv=notrunc
fi

# Flash U-Boot FIT image to uboot partition (per-device charge-enabled image)
UBOOT_IMG="${BSP_PATH}/uboot-${UNIT}.img"
if [ ! -f "${UBOOT_IMG}" ]; then
  UBOOT_IMG="${BSP_PATH}/uboot.img"
fi
if [ -f "${UBOOT_IMG}" ]; then
  echo "Flashing U-Boot FIT image ($(basename ${UBOOT_IMG}))..."
  sudo dd if=${UBOOT_IMG} of=$LOOP_DEV bs=$SECTOR_SIZE seek=16384 conv=notrunc
fi

# Copy U-Boot image for potential recovery
sudo mkdir -p Arkbuild/usr/local/bin/
if [ -f "${UBOOT_IMG}" ]; then
  sudo cp ${UBOOT_IMG} Arkbuild/usr/local/bin/uboot.img.emuelec
fi

# Create config directory for kernel version info
sudo mkdir -p Arkbuild/boot/
echo "${KERNEL_VERSION}" | sudo tee Arkbuild/boot/kernel_version

echo "Kernel build and installation complete"
echo "  Kernel: ${KERNEL_VERSION}"
echo "  Mali: handled by build_deps.sh (${whichmali})"
echo "  DTB: ${UNIT_DTB}.dtb"

# Note: No cd needed - we should still be in the original directory
