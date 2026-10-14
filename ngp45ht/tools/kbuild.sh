#!/bin/bash
# Rebuild kernel Image + dtbs + modules for NGP45HT with ngp45ht_defconfig.
# NOT for the shipped Image: this switches the build tree to ngp45ht_defconfig,
# the slim config that booted with no usable network.  Use imgbuild.sh, which
# configures rg43h_defconfig and relinks only what changed.
set -x
SRC=/mnt/f/darkos/kernel_rk3562
BLD=/root/ngp/kernel_rk3562
OUT=/mnt/f/darkos/_work/ngpout
mkdir -p "$OUT"
cd "$BLD" || exit 1

FILES="arch/arm64/configs/ngp45ht_defconfig
arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dts
arch/arm64/boot/dts/rockchip/rk3562-darkos.dtsi
arch/arm64/boot/dts/rockchip/Makefile
drivers/input/joystick/rk3562-joystick.c"

for f in $FILES; do
  if [ -f "$SRC/$f" ]; then
    if cmp -s "$SRC/$f" "$BLD/$f"; then echo "SAME  $f"; else echo "COPY  $f"; cp -f "$SRC/$f" "$BLD/$f"; fi
  else
    echo "MISSING IN SRC $f"
  fi
done
chown -R root:root "$BLD" 2>/dev/null

export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make ngp45ht_defconfig >/dev/null 2>&1 || { echo DEFCONFIG_FAIL; exit 1; }
grep -E "CONFIG_MALI400|CONFIG_MALI_MIDGARD|CONFIG_MALI_BIFROST=|CONFIG_TEE|CONFIG_OPTEE|CONFIG_PSTORE_RAM|CONFIG_DETECT_HUNG_TASK|CONFIG_SOFTLOCKUP_DETECTOR|CONFIG_WQ_WATCHDOG|CONFIG_PSTORE_PMSG|CONFIG_ZRAM_WRITEBACK|CONFIG_LOCALVERSION" .config
echo "=== build ==="
( make -j16 Image modules dtbs > /root/ngp/kbuild.log 2>&1; echo "BUILD_EXIT=$?" )
grep -nE "^[^ ]*error:|Error |fatal error" /root/ngp/kbuild.log | head -20
tail -6 /root/ngp/kbuild.log
ls -l arch/arm64/boot/Image arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dtb 2>&1
