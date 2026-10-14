#!/bin/bash
# Rebuild Image + dtbs from the ORIGINAL rg43h config (so the rootfs's prebuilt
# aic8800 .ko keep matching), keeping the joystick driver change and the NGP DTS.
set -x
SRC=/mnt/f/darkos/kernel_rk3562
BLD=/root/ngp/kernel_rk3562
OUT=/mnt/f/darkos/_work/ngpout
mkdir -p "$OUT"
cd "$BLD" || exit 1
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-

cp -f "$SRC/drivers/input/joystick/rk3562-joystick.c" drivers/input/joystick/rk3562-joystick.c
cp -f "$SRC/arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dts" arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dts

make rg43h_defconfig > /root/ngp/cfg.log 2>&1
echo "CFG_EXIT=$?"
grep -E "CONFIG_MODVERSIONS|CONFIG_JOYSTICK_RK3562|CONFIG_AIC|CONFIG_LOCALVERSION=" .config

make -j16 Image dtbs > /root/ngp/kbuild2.log 2>&1
echo "BUILD_EXIT=$?"
grep -nE "error:|Error [0-9]" /root/ngp/kbuild2.log | head -10
ls -l arch/arm64/boot/Image arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dtb
cp -f arch/arm64/boot/Image "$OUT/Image-rg43hcfg"
cp -f arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dtb "$OUT/rk3562-ngp45ht.dtb"
sync
sha256sum "$OUT/Image-rg43hcfg" "$OUT/rk3562-ngp45ht.dtb"
echo "MODVER_MAGIC:"
scripts/mod/modpost --version 2>/dev/null | head -1
echo "STAGE2_DONE"
