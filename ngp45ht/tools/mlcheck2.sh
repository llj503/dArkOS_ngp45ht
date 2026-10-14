#!/bin/bash
# Pull the mainline RK3562 dtsi + EVB board dts from kernel.org's cgit (GitHub raw
# is rate-limited from here) and grep the subsystems this handheld depends on.
set -u
D=/root/ml
mkdir -p "$D"
cd "$D" || exit 1
BASE=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain
H=v7.2
for f in arch/arm64/boot/dts/rockchip/rk3562.dtsi arch/arm64/boot/dts/rockchip/rk3562-evb2-v10.dts arch/arm64/boot/dts/rockchip/rk3562-pinctrl.dtsi; do
    out=$(basename "$f")
    code=$(curl -s -o "$out" -w "%{http_code}" "$BASE/$f?h=$H")
    echo "$out HTTP=$code bytes=$(wc -c < "$out")"
done
echo
echo "=== compatibles in mainline rk3562.dtsi ==="
grep -oE 'compatible = "[^"]+"' rk3562.dtsi | sort -u
echo
echo "=== subsystem presence (node labels) ==="
for pat in gpu dsi vop iommu saradc usb2phy u2phy ehci ohci dwc3 xhci sdmmc mmc mmc0 mmc1 i2s sai spdif pwm thermal tsadc crypto dmc rga vpu rkvdec vepu hevc vdpu venc power_domain pd_ gpio pinctrl; do
    n=$(grep -cE "^\s*${pat}[a-z0-9_-]*\s*:" rk3562.dtsi 2>/dev/null || echo 0)
    echo "  $pat -> $n"
done
echo
echo "=== EVB board dts: what it turns on ==="
grep -nE '^&[a-z0-9_]+' rk3562-evb2-v10.dts | head -40
