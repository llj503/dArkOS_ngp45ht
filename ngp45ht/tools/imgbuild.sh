#!/bin/bash
# Incremental rebuild of the shipped rg43h_defconfig Image + our DTB, staging both
# into _work/ngpout for deploy_kernel.py.  kbuild.sh must not be used here: it
# switches the tree to ngp45ht_defconfig, the config that killed networking.
set -x
SRC=/mnt/f/darkos/kernel_rk3562
BLD=/root/ngp/kernel_rk3562
OUT=/mnt/f/darkos/_work/ngpout
mkdir -p "$OUT"
cd "$BLD" || exit 1

for f in arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dts \
         drivers/input/joystick/rk3562-joystick.c; do
  if cmp -s "$SRC/$f" "$BLD/$f"; then echo "SAME  $f"; else echo "COPY  $f"; cp -f "$SRC/$f" "$BLD/$f"; fi
done

export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make rg43h_defconfig >/dev/null 2>&1 || { echo DEFCONFIG_FAIL; exit 1; }
grep -E "CONFIG_JOYSTICK_RK3562|CONFIG_WEXT" .config | head -4
( make -j16 Image dtbs > /root/ngp/imgbuild.log 2>&1; echo "BUILD_EXIT=$?" )
grep -nE "error:|Error [0-9]|fatal error" /root/ngp/imgbuild.log | head -15
grep -n "rk3562-joystick" /root/ngp/imgbuild.log | head -5
tail -4 /root/ngp/imgbuild.log
cp -f arch/arm64/boot/Image "$OUT/Image"
cp -f arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dtb "$OUT/rk3562-ngp45ht.dtb"
sync
sha256sum "$OUT/Image" "$OUT/rk3562-ngp45ht.dtb"
echo STAGE_DONE
