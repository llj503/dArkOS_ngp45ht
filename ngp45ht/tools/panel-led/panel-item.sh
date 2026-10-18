#!/bin/bash
# panel-item.sh [brightness|contrast|saturation|hue|led|stick]
#
# 面板/灯光调节的统一启动器。
#   无参数     -> 打开完整界面（6 项，上下切换）
#   带 item    -> 只调那一项，上下键锁定（供 选项 → 面板调节 → 亮度 / … 用）
#
# 优先用图形版 ngp-panel-gui（SDL2 + KMSDRM，画风照 ES 主题，字体用 ES 资源里的
# DroidSans/OpenSans）；它返回 2 表示拿不到显示（多半是 ES 还握着 DRM master），
# 这时回退到 panelui.py 的控制台界面。

PANELDIR=/opt/ngp-panel
GUI=$PANELDIR/ngp-panel-gui
CJKFONT=/usr/share/consolefonts/Unifont-CJK-panel.psf.gz
LATINFONT=/usr/share/consolefonts/Lat7-Terminus20x10.psf.gz

# ES 的 gptokeyb 会把手柄吞成键盘事件，两个界面都自己读 evdev，先让它让开
pgrep -f gptokeyb | sudo xargs -r kill -9 2>/dev/null
# 状态灯 GPIO 需要 root 导出一次；ark 免密 sudo
sudo /usr/bin/ledcontrol >/dev/null 2>&1

if [ -x "$GUI" ]; then
	if [ -n "${1:-}" ]; then
		"$GUI" --only "$1"
	else
		"$GUI"
	fi
	rc=$?
	if [ $rc -ne 2 ]; then
		printf "\033c" > /dev/tty1
		exit $rc
	fi
fi

# ---- 回退：控制台界面 ----
sudo chmod 666 /dev/tty1 2>/dev/null
printf "\e[?25l" > /dev/tty1
export TERM=linux
export XDG_RUNTIME_DIR=/run/user/$UID/
sudo setfont "$CJKFONT" 2>/dev/null

printf "\033c" > /dev/tty1
if [ -n "${1:-}" ]; then
	python3 "$PANELDIR/panelui.py" --only "$1"
else
	python3 "$PANELDIR/panelui.py"
fi
rc=$?

printf "\033c" > /dev/tty1
sudo setfont "$LATINFONT" 2>/dev/null
printf "\e[?25h" > /dev/tty1
exit $rc
