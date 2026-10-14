#!/bin/bash
# Fetch the mainline rk3562 device tree + board list so the "does mainline support
# this SoC" question is answered by grep on real source, not by a summary.
set -u
D=/root/ml
mkdir -p "$D"
cd "$D" || exit 1
for ref in v7.2 v7.2.10 v6.12 master; do
    url=https://raw.githubusercontent.com/torvalds/linux/$ref/arch/arm64/boot/dts/rockchip/rk3562.dtsi
    code=$(curl -s -o "rk3562-$ref.dtsi" -w "%{http_code}" "$url")
    echo "$ref HTTP=$code bytes=$(wc -c < "rk3562-$ref.dtsi")"
done
echo "=== what did the 404 body look like ==="
head -c 120 rk3562-v7.2.dtsi; echo
echo "=== rk3562 board files present in mainline master ==="
curl -s "https://api.github.com/repos/torvalds/linux/contents/arch/arm64/boot/dts/rockchip?ref=master" \
  | grep -oE '"name": "rk3562[^"]*"' | head -20
