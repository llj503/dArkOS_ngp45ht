#!/bin/bash
# fix-cjk-fonts.sh — 修「351Files / 文件管理器」的中文乱码 + 字体发虚/像素感
#
# === 症状与根因（2026-10-20 在 192.168.31.194 实测）===
# 1) 351Files 中文全是豆腐块
#    /opt/351Files/res/NotoSans-Regular.ttf 与 NotoSansMono-Regular.ttf 是**纯拉丁** Noto，
#    一个汉字字形都没有。
# 2) 文件管理器（DinguxCommander）"部分乱码"
#    二进制里**硬编码**加载 /home/ark/.config/retroarch/assets/ozone/bold.ttf（Inter UI Bold），
#    只含常用汉字子集 —— 中/文 能显示，测/试/目/录 是方框。
# 3) 换字体后"像素感、不顺滑"
#    ！这是换字体时引入的：文泉驿正黑（wy_scorpio.ttf）**重度 hint**，字形贴像素网格，
#    小字号下很硬。改用 Noto Sans CJK（hinting 温和）后立刻顺滑。
# 4) 351Files 列表没有图标
#    程序按字号找 res/<size>/，实际只有 24/32/48/58/64，缺 **28**，
#    日志一直报 Unable to load ./res/28/file.png。
#
# === 不要试图给 Shaded 加抗锯齿 ===
# 两个程序都用 TTF_RenderUTF8_Shaded。SDL_ttf 的 Shaded **本来就是 8 位抗锯齿**
# （只是背景不透明）。用 LD_PRELOAD 重定向到 Blended 反而更糟：Shaded 返回 8 位调色板面，
# 换成 32 位 ARGB 会破坏调用方取像素的假设 —— 实测灰度级数从 178 掉到 16，更花。
#
# 用法：fix-cjk-fonts.sh [--revert]
set -u

REG=/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc
BOLD=/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc
R=/opt/351Files/res
OZ=/home/ark/.config/retroarch/assets/ozone/bold.ttf

revert=0
[ "${1:-}" = "--revert" ] && revert=1

for f in "$REG" "$BOLD"; do
	[ -f "$f" ] || { echo "缺少 $f"; exit 1; }
done

echo "== 351Files 字体 =="
for f in NotoSans-Regular.ttf NotoSansMono-Regular.ttf; do
	[ -f "$R/$f" ] || continue
	if [ $revert -eq 1 ]; then
		[ -f "$R/$f.bak-ngp" ] && cp -f "$R/$f.bak-ngp" "$R/$f" && echo "  还原 $f"
	else
		[ -f "$R/$f.bak-ngp" ] || cp -a "$R/$f" "$R/$f.bak-ngp"
		cp -f "$REG" "$R/$f" && echo "  替换 $f -> Noto Sans CJK"
	fi
done

echo "== 351Files 缺的 28px 图标目录 =="
if [ $revert -eq 1 ]; then
	[ -d "$R/28" ] && rm -rf "$R/28" && echo "  移除 res/28"
else
	[ -d "$R/28" ] || { cp -a "$R/32" "$R/28" && echo "  res/28 <- res/32"; }
fi

echo "== 文件管理器字体（RA ozone bold.ttf）=="
if [ -f "$OZ" ]; then
	if [ $revert -eq 1 ]; then
		[ -f "$OZ.bak-ngp" ] && cp -f "$OZ.bak-ngp" "$OZ" && echo "  还原 bold.ttf"
	else
		[ -f "$OZ.bak-ngp" ] || cp -a "$OZ" "$OZ.bak-ngp"
		cp -f "$BOLD" "$OZ" && echo "  替换 bold.ttf -> Noto Sans CJK Bold"
	fi
fi
echo "完成（RA 的 ozone 菜单也会用这个字体，属于已知副作用）"
