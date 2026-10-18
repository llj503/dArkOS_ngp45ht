#!/bin/sh
# ngp-wifi-watchdog.sh — 开机确保 AIC8800 USB 网卡真的拿到 IPv4
#
# 现象（2026-10-18 复现两次，约 50%）：冷/热重启后设备进了 ES，但 wlan0 没有 IP，
# 手动「重连一下」就恢复。NM 的 autoconnect 是开着的（retries 默认 -1 ≈ 4 次），
# 怀疑是 USB 网卡枚举/固件加载比 NM 的自动重试窗口慢，NM 先放弃了。
#
# 策略（有上限，不会卡住启动）：
#   1) 等 60 s，看 wlan0 是否已有 IPv4
#   2) 没有 → wifi radio off/on + nmcli con up
#   3) 再没有 → USB unbind/bind（a69c:88dc）后重连
#   4) 仍失败就记日志退出，不影响系统
#
# 日志：/var/log/ngp-wifi-watchdog.log

LOG=/var/log/ngp-wifi-watchdog.log
PROFILE="$1"

say() { echo "$(date '+%F %T') $*" >> "$LOG" 2>/dev/null; }

have_ip() {
	ip -4 addr show wlan0 2>/dev/null | grep -q 'inet '
}

profile_name() {
	if [ -n "$PROFILE" ]; then
		echo "$PROFILE"
		return
	fi
	nmcli -t -f NAME,TYPE con show 2>/dev/null |
		awk -F: '$2 == "802-11-wireless" { print $1; exit }'
}

usb_reset() {
	for f in /sys/bus/usb/devices/*/idVendor; do
		[ -r "$f" ] || continue
		[ "$(cat "$f" 2>/dev/null)" = "a69c" ] || continue
		port=$(basename "$(dirname "$f")")
		say "USB reset $port"
		echo "$port" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null
		sleep 3
		echo "$port" > /sys/bus/usb/drivers/usb/bind 2>/dev/null
		sleep 8
	done
}

wait_ip() { # wait_ip <次数> <间隔秒>
	i=0
	while [ "$i" -lt "$1" ]; do
		have_ip && return 0
		sleep "$2"
		i=$((i + 1))
	done
	have_ip
}

say "watchdog start"

# 1) 正常情况：给它 60 s
if wait_ip 30 2; then
	say "wlan0 已就绪，无需干预"
	exit 0
fi

P=$(profile_name)
say "超时未拿到 IP，profile=${P:-<none>}"

# 2) 简单重连
nmcli radio wifi off >/dev/null 2>&1
sleep 2
nmcli radio wifi on >/dev/null 2>&1
sleep 4
[ -n "$P" ] && nmcli con up "$P" >/dev/null 2>&1
if wait_ip 10 2; then
	say "重连成功"
	exit 0
fi

# 3) USB 复位
usb_reset
nmcli radio wifi on >/dev/null 2>&1
sleep 2
[ -n "$P" ] && nmcli con up "$P" >/dev/null 2>&1
if wait_ip 20 3; then
	say "USB 复位后连上"
	exit 0
fi

say "仍失败，放弃（不影响系统启动）"
exit 1
