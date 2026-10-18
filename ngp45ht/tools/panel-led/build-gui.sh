#!/bin/sh
# build-gui.sh — 在设备上编译图形版面板调节界面（ngp-panel-gui）
#
# 为什么要在设备上编：这台机器上 gcc / make / SDL2 头文件都在（ES 自己就是用它编的），
# 但 **SDL2_ttf 只装了运行库，没有 SDL2_ttf.h** —— 所以 ngp_panel_gui.c 里手写了
# TTF_* 的原型，编译时直接链 libSDL2_ttf-2.0.so.0（没有 .so 开发符号链接）。
#
# 用法：在本目录执行 ./build-gui.sh（root 或能写 /opt/ngp-panel 的用户）
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TTFLIB=/usr/lib/aarch64-linux-gnu/libSDL2_ttf-2.0.so.0
OUT=${1:-/opt/ngp-panel/ngp-panel-gui}

[ -f "$TTFLIB" ] || { echo "缺少 $TTFLIB"; exit 1; }

gcc -O2 -Wall -I/usr/include/SDL2 -o "$OUT" "$HERE/ngp_panel_gui.c" \
    -lSDL2 "$TTFLIB" -lm
echo "built: $OUT"
sha256sum "$OUT"

# 网络设置界面（同一套框架）
OUT2=${2:-/opt/ngp-panel/ngp-wifi-gui}
gcc -O2 -Wall -I/usr/include/SDL2 -o "$OUT2" "$HERE/ngp_wifi_gui.c" \
    -lSDL2 "$TTFLIB" -lm
echo "built: $OUT2"
sha256sum "$OUT2"
