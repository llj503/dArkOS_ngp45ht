#!/bin/bash
# Re-apply the final DTS, rebuild dtbs, stage Image + DTB for deployment.
set -x
SRC=/mnt/f/darkos/kernel_rk3562
BLD=/root/ngp/kernel_rk3562
OUT=/mnt/f/darkos/_work/ngpout
mkdir -p "$OUT"
cd "$BLD"
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-

cp -f "$SRC/arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dts" \
      arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dts
cp -f "$SRC/drivers/input/joystick/rk3562-joystick.c" drivers/input/joystick/rk3562-joystick.c
touch arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dts

make -j16 dtbs > /root/ngp/dtbbuild.log 2>&1
echo "DTB_EXIT=$?"
grep -iE "error|warning: .*io-channels" /root/ngp/dtbbuild.log | head -10 || true
ls -l arch/arm64/boot/Image arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dtb

cp -f arch/arm64/boot/Image "$OUT/Image"
cp -f arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dtb "$OUT/rk3562-ngp45ht.dtb"
sync
sha256sum "$OUT/Image" "$OUT/rk3562-ngp45ht.dtb"

echo "=== 编译出的 dtb 里摇杆节点 ==="
dtc -I dtb -O dts arch/arm64/boot/dts/rockchip/rk3562-ngp45ht.dtb 2>/dev/null \
  | sed -n '/play_joystick/,/key-gpios-map/p' | grep -E "io-channels|invert|l_xy|r_xy|left-stick" || true
echo "STAGE_DONE"
