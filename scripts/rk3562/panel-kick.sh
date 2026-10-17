#!/bin/sh
# Revision A workaround. On the RK915 revision of the RG52 Mini the panel stays
# black, backlight on, once the kernel has the display; a suspend/resume cycle
# brings it back. The same black screen can be produced on revision B by
# switching the display off and on again quickly:
#
#   off/on in 38-41 ms                     -> black, backlight on
#   off for 120 ms                         -> black
#   off for 150 ms and more                -> picture
#
# What needs the time is the DSI link and the panel, not a power domain: the
# DSI host and D-PHY are in none. Two things in the kernel now address it -
# the stock panel-exit-sequence delays (128 ms after display-off, 30 ms after
# sleep-in) and a 500 ms minimum DSI off time (dw_mipi_dsi.rg52_min_off_ms).
# This stays as a third line until a revision A unit is confirmed to come up
# without it: switch the display off for longer than that and back on, before
# EmulationStation takes it.
#
# fbcon has to be unbound for it - fbcon would switch the output back 38 ms
# after the blank, the very failure this cures - and EmulationStation must not
# be running yet: once a DRM master holds the device the blank gets -EBUSY.
#
# /boot/panel-kick-off on the FAT partition disables it; /boot/panel-kick-force
# runs it on any revision.

is_rev_a() {
    # Revision A has no Type-C controller. Revision B's HUSB311 is built in and
    # bound long before userspace, so this needs no waiting.
    ! ls /sys/bus/i2c/drivers/husb311/ 2>/dev/null | grep -q -- '-004e$'
}

if [ -e /boot/panel-kick-off ]; then
    logger -t panel-kick "disabled by /boot/panel-kick-off"
    exit 0
elif [ -e /boot/panel-kick-force ]; then
    logger -t panel-kick "forced by /boot/panel-kick-force"
elif ! is_rev_a; then
    exit 0
fi

# Loading rk915 power-cycles the Wi-Fi rail, and it happens around the time the
# display first comes up. Let it finish first so it cannot disturb the panel
# after this has run. Waited for here rather than with After= in the unit, so
# that revision B, which has exited above, never holds EmulationStation back
# for the Wi-Fi driver.
# It may not even have been started yet when this runs, so wait for a final
# state rather than for "activating" to end. Nothing it depends on waits for
# EmulationStation, so this cannot deadlock; 30 s caps it anyway.
i=0
while :; do
    case "$(systemctl is-active wifi-driver-load 2>/dev/null)" in
        active|failed) break ;;
    esac
    [ $i -ge 300 ] && break
    sleep 0.1; i=$((i + 1))
done
logger -t panel-kick "wifi-driver-load $(systemctl is-active wifi-driver-load 2>/dev/null) after $((i * 100)) ms"

FB=/sys/class/graphics/fb0/blank
VT=
for v in /sys/class/vtconsole/vtcon*; do
    grep -q "frame buffer" "$v/name" 2>/dev/null && VT=$v/bind
done

logger -t panel-kick "switching the display off and on before EmulationStation"
[ -n "$VT" ] && echo 0 > "$VT"
echo 4 > "$FB"
sleep 0.6
echo 0 > "$FB"
[ -n "$VT" ] && echo 1 > "$VT"
logger -t panel-kick "display back on"
