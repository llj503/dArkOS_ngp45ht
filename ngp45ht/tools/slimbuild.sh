#!/bin/bash
# Reproduce the shipped NGP45HT kernel: slim ngp45ht_defconfig Image + the board
# DTB + the two out-of-tree AIC8800DC WiFi modules that go with it.  They are one
# unit -- CONFIG_MODVERSIONS is off and the vermagic is identical across configs,
# so a mismatched .ko still loads and then misbehaves; never ship one without the
# other.
#
# Run inside WSL as root (the build tree is root-owned):
#   wsl -u root bash -lc "bash /mnt/f/darkos/_work/slimbuild.sh"
#
# Kernel source required at $SRC (the Windows-side tree, patched with
# kernel-patches/*.patch), driver source at $DRV:
#   git clone https://github.com/AveyondFly/aic8800-usb /root/ngp/aic8800-usb
set -x
SRC=/mnt/f/darkos/kernel_rk3562
BLD=/root/ngp/kernel_rk3562
DRV=/root/ngp/aic8800-usb
OUT=/mnt/f/darkos/_work/ngpout
LOG=/root/ngp/slimbuild.log
mkdir -p "$OUT/modules-ngp45ht"
cd "$BLD" || exit 1

# Never trust the tree to still hold the port's edits; re-copy them every time.
for f in arch/arm64/configs/ngp45ht_defconfig \
         arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dts \
         arch/arm64/boot/dts/rockchip/rk3562-darkos.dtsi \
         arch/arm64/boot/dts/rockchip/Makefile \
         drivers/input/joystick/rk3562-joystick.c; do
    if [ -f "$SRC/$f" ]; then
        cp -f "$SRC/$f" "$BLD/$f"
    else
        echo "MISSING IN SRC $f"; exit 1
    fi
done

export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KBUILD_BUILD_HOST=ngp45ht
make ngp45ht_defconfig > /root/ngp/slimcfg.log 2>&1
echo "CFG_EXIT=$?"
grep -E "CONFIG_LOCALVERSION=|CONFIG_JOYSTICK_RK3562|CONFIG_PM_DEVFREQ|CONFIG_BLK_DEV_LOOP" .config

( make -j16 Image modules dtbs > $LOG 2>&1; echo "KERNEL_EXIT=$?" )
grep -nE "error:|Error [0-9]|fatal error" $LOG | head -10
tail -3 $LOG
[ -f arch/arm64/boot/Image ] || exit 1

# The driver's own Makefile hardcodes a vendor KDIR, so drive the kernel build
# directly and point M= at the driver tree.
( make -C "$BLD" M="$DRV" modules > /root/ngp/slimmod.log 2>&1; echo "MOD_EXIT=$?" )
grep -nE "error:|Error [0-9]" /root/ngp/slimmod.log | head -10
tail -3 /root/ngp/slimmod.log
for ko in aic8800_fdrv/aic8800_fdrv_usb.ko aic_load_fw/aic_load_fw_usb.ko; do
    [ -f "$DRV/$ko" ] || { echo "NO MODULE $ko"; exit 1; }
done

cp -f arch/arm64/boot/Image "$OUT/Image-ngp45ht"
cp -f arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dtb "$OUT/rk3562-ngp45ht.dtb"
cp -f "$DRV/aic8800_fdrv/aic8800_fdrv_usb.ko" "$DRV/aic_load_fw/aic_load_fw_usb.ko" "$OUT/modules-ngp45ht/"
sync
echo "=== staged ==="
sha256sum "$OUT/Image-ngp45ht" "$OUT/rk3562-ngp45ht.dtb" \
    "$OUT/modules-ngp45ht/aic8800_fdrv_usb.ko" "$OUT/modules-ngp45ht/aic_load_fw_usb.ko"
ls -l "$OUT/Image-ngp45ht"
echo "SLIMBUILD_DONE"
