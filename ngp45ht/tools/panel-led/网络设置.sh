#!/bin/bash
# 选项 → 网络设置：图形版（SDL2 + KMSDRM），拿不到显示时回退到原来的 dialog 版 Wifi.sh
#
# 图形界面里：WiFi 开关 / 当前连接(SSID+IP) / 附近网络(信号+加密) / SSH 开关，
# 连加密网络会弹屏幕键盘输密码。

GUI=/opt/ngp-panel/ngp-wifi-gui
FALLBACK=/opt/ngp-wifi/wifi-dialog.sh

# 手柄不要被 gptokeyb 吞成键盘事件，图形版自己读 evdev
pgrep -f gptokeyb | sudo xargs -r kill -9 2>/dev/null

if [ -x "$GUI" ]; then
	"$GUI"
	rc=$?
	if [ $rc -ne 2 ]; then
		printf "\033c" > /dev/tty1
		exit $rc
	fi
fi

exec "$FALLBACK"
