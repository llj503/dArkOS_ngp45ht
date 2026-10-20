#!/bin/bash
# fix-cjk-fonts.sh — 修「351Files / 文件管理器」中文文件名乱码
#
# 根因（2026-10-20 在 192.168.31.194 实测）：
#   351Files       → /opt/351Files/res/NotoSans-{Regular,Mono}-Regular.ttf 是**纯拉丁** Noto，
#                    没有任何汉字字形 → 中文全部渲染成同一个豆腐块。
#   DinguxCommander→ 二进制里硬编码加载 /home/ark/.config/retroarch/assets/ozone/bold.ttf
#                    （Inter UI Bold，只有常用汉字子集）→ 「中/文」能显示，
#                    「测/试/目/录」是方框，就是用户说的"部分乱码"。
#
# 做法：两处都换成文泉驿正黑（/opt/dingux/res/wy_scorpio.ttf，拉丁+全中文，系统自带）。
# 副作用：RA 的 ozone 菜单字体跟着变（失去粗体感），可随时用 --revert 还原。
#
# 用法：fix-cjk-fonts.sh [--revert]
set -u
SRC=/opt/dingux/res/wy_scorpio.ttf
R=/opt/351Files/res
OZ=/home/ark/.config/retroarch/assets/ozone/bold.ttf

revert=0
[ "${1:-}" = "--revert" ] && revert=1

[ -f "$SRC" ] || { echo "缺少 $SRC"; exit 1; }

for f in NotoSans-Regular.ttf NotoSansMono-Regular.ttf; do
	[ -f "$R/$f" ] || continue
	if [ $revert -eq 1 ]; then
		[ -f "$R/$f.bak-ngp" ] && cp -f "$R/$f.bak-ngp" "$R/$f" && echo "还原 $R/$f"
	else
		[ -f "$R/$f.bak-ngp" ] || cp -a "$R/$f" "$R/$f.bak-ngp"
		cp -f "$SRC" "$R/$f" && echo "替换 $R/$f"
	fi
done

if [ -f "$OZ" ]; then
	if [ $revert -eq 1 ]; then
		[ -f "$OZ.bak-ngp" ] && cp -f "$OZ.bak-ngp" "$OZ" && echo "还原 $OZ"
	else
		[ -f "$OZ.bak-ngp" ] || cp -a "$OZ" "$OZ.bak-ngp"
		cp -f "$SRC" "$OZ" && echo "替换 $OZ"
	fi
fi
