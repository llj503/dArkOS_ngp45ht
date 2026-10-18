#!/bin/sh
# ngp-battery-shim.sh — 修正 RK817 充电驱动"永远 Charging"的假状态
#
# 事实（2026-10-18 实测，未插电）：
#   /sys/class/power_supply/battery/current_now = -497000  (=-0.5 A，在放电)
#   /sys/class/power_supply/battery/voltage_now = 3954000  (3.95 V，不是充电电压)
#   /sys/class/power_supply/battery/status      = Charging  ← 假的
#   /sys/class/power_supply/ac/online           = 1         ← 也是假的
#
# ES 的 BatteryIndicatorComponent 读 battery/status 判断要不要画闪电，
# 于是不插电也一直显示闪电图标。
#
# 做法：用 tmpfs 里一个受我们控制的小文件 bind-mount 覆盖
# /sys/class/power_supply/battery/status，内容按 current_now 的符号推断。
# 不碰内核、不碰驱动，卸载（umount 该文件）即可完全还原。
#
# 判定（带滞回，避免在 0 附近抖动）：
#   current_now > +50 mA  -> Charging
#   current_now < -20 mA  -> Discharging
#   之间                  -> 保持上一次状态（充满后涓流/静置时不会乱跳）

REAL_CUR=/sys/class/power_supply/battery/current_now
TARGET=/sys/class/power_supply/battery/status
RUNDIR=/run/ngp-power
SHIM=$RUNDIR/battery-status

mkdir -p "$RUNDIR" 2>/dev/null
[ -f "$SHIM" ] || echo "Discharging" > "$SHIM" 2>/dev/null

shim_mounted() {
	mountpoint -q "$TARGET" 2>/dev/null
}

if ! shim_mounted; then
	mount --bind "$SHIM" "$TARGET" 2>/dev/null || {
		echo "ngp-battery-shim: bind mount failed, giving up" >&2
		exit 1
	}
fi

prev=$(cat "$SHIM" 2>/dev/null)
case "$prev" in
	Charging|Discharging|Full) ;;
	*) prev=Discharging ;;
esac

while :; do
	cur=$(cat "$REAL_CUR" 2>/dev/null)
	case "$cur" in
	''|*[!-0-9]*) cur=0 ;;
	esac

	if [ "$cur" -gt 50000 ]; then
		st=Charging
	elif [ "$cur" -lt -20000 ]; then
		st=Discharging
	else
		st=$prev
	fi

	if [ "$st" != "$prev" ]; then
		echo "$st" > "$SHIM" 2>/dev/null
		prev=$st
	fi
	sleep 3
done
