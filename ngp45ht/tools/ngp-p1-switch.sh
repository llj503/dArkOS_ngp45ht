#!/bin/bash
# Give an external gamepad (USB/2.4G XInput receiver, or a BLE-HID pad) player 1 by
# unplugging the built-in pad from the input layer while the external one is present,
# and putting it back when it goes away.
#
# Safe on this board, and measured rather than assumed:
#   * rk3562-joystick registers its input device with devm_input_allocate_device(), so
#     unbind unregisters it even though the driver has no .remove hook;
#   * the driver touches no regulator, and TF2's rails are regulator-always-on in the
#     board DTS -- across unbind/rebind /mnt/roms2 stayed mounted and the mergerfs pool
#     still served all 2021 /roms/fbneo entries;
#   * rebind restored the same event3/js0 numbers and the by-path symlinks.
#
#   ngp-p1-switch.sh status            what is bound right now
#   ngp-p1-switch.sh apply             re-evaluate (called by udev, safe to run by hand)
#   ngp-p1-switch.sh external|builtin  force one side
#   ngp-p1-switch.sh install|uninstall the udev rule
DRV=/sys/bus/platform/drivers/rk3562-joystick
DEV=play_joystick
LOG=/var/log/ngp-p1-switch.log

log() { echo "$(date '+%F %T') $*" >>"$LOG"; }

# Count external gamepads straight from the kernel.  udev's by-id links are not usable
# here: on "add" they are created after RUN+= fires, and on "remove" they may not be gone
# yet.  Bus=0003 is USB (a 2.4G XInput receiver enumerates as 045e:028e), Bus=0005 is
# Bluetooth (a BLE-HID pad); the built-in pad is Bus=0019 and never counts.
ext_count() {
  awk '
    /^I: Bus=000[35]/ { ext = 1; next }
    /^I: /            { ext = 0; next }
    /^H: Handlers=/   { if (ext && $0 ~ /(=| )js[0-9]+( |$)/) n++ }
    END { print n + 0 }' /proc/bus/input/devices
}

bound() { [ -e "$DRV/$DEV" ]; }

apply() {
  local n; n=$(ext_count)
  if [ "$n" -gt 0 ]; then
    if bound; then
      echo "$DEV" >"$DRV/unbind" && log "external pads=$n -> $DEV unbound (external is P1)"
    fi
  else
    if ! bound; then
      echo "$DEV" >"$DRV/bind" && log "external pads=0 -> $DEV rebound (built-in is P1)"
    fi
  fi
}

status() {
  echo "external gamepads     : $(ext_count)   (USB bus 0003 + BT bus 0005)"
  echo "built-in pad bound    : $(bound && echo yes || echo no)"
  echo "input devices         : $(grep -a '^N: Name=' /proc/bus/input/devices | sed 's/N: Name=//; s/"//g' | tr '\n' ' ')"
  echo "joystick nodes        : $(ls /dev/input/ | grep -a '^js' | tr '\n' ' ')"
  echo "log                   : $(wc -l <"$LOG" 2>/dev/null || echo 0) lines in $LOG"
  tail -3 "$LOG" 2>/dev/null | sed 's/^/  /'
}

case "${1:-status}" in
  status)   status ;;
  apply|udev) apply ;;
  external) bound && { echo "$DEV" >"$DRV/unbind"; log "forced: $DEV unbound"; }
            status ;;
  builtin)  bound || { echo "$DEV" >"$DRV/bind"; log "forced: $DEV rebound"; }
            status ;;
  install)
    cat >/etc/udev/rules.d/98-external-pad-p1.rules <<'EOR'
# External USB/2.4G/BLE gamepad takes player 1: drop the built-in pad while it is
# present, restore it when it goes.  The script re-reads /proc/bus/input/devices, so it
# does not depend on udev having finished creating or removing the by-id links.
ACTION=="add",    SUBSYSTEM=="input", ENV{ID_BUS}=="usb|bluetooth", ENV{ID_INPUT_JOYSTICK}=="1", RUN+="/usr/local/sbin/ngp-p1-switch.sh udev"
ACTION=="remove", SUBSYSTEM=="input", ENV{ID_BUS}=="usb|bluetooth", ENV{ID_INPUT_JOYSTICK}=="1", RUN+="/usr/local/sbin/ngp-p1-switch.sh udev"
# The built-in pad binds late on some boots; re-evaluate then too.
ACTION=="add",    SUBSYSTEM=="platform", DRIVER=="rk3562-joystick", RUN+="/usr/local/sbin/ngp-p1-switch.sh udev"
EOR
    chmod 644 /etc/udev/rules.d/98-external-pad-p1.rules
    udevadm control --reload 2>/dev/null || /sbin/udevadm control --reload
    echo "rule installed + udev reloaded"; apply; status ;;
  uninstall)
    rm -f /etc/udev/rules.d/98-external-pad-p1.rules
    udevadm control --reload 2>/dev/null || /sbin/udevadm control --reload
    bound || { echo "$DEV" >"$DRV/bind"; log "rule removed -> $DEV rebound"; }
    echo "rule removed, built-in pad restored"; status ;;
  *) echo "usage: $0 status|apply|external|builtin|install|uninstall"; exit 1 ;;
esac
