#!/bin/bash
# paneladj.sh — NGP45HT panel colour adjustment (ported from ROCKNIX)
#
# Upstream: AveyondFly/distribution_rocknix (branch next),
#   projects/ROCKNIX/packages/rocknix/sources/scripts/paneladj
#   (originally JELOS, GPL-2.0) — the RK356X branch of that script.
#
# The mechanism is unchanged: on RK356X the four DRM *connector* properties
# brightness/contrast/saturation/hue (0-100, 50 = neutral) drive the VOP2
# BCSH post-processor (see rockchip_drm_vop2.c: vop2_tv_config_update).
# They are written with modetest upstream; here panelprop.py does the same
# drmModeObjectSetProperty() call through libdrm ctypes, so no package has to
# be installed (and /dev/dri/card0 is group video, ark is in video, so no
# sudo is needed either).
#
# Differences from upstream, all deliberate:
#   * values persist to /opt/ngp-panel/panel.conf instead of ROCKNIX's
#     get_setting/set_setting sysconfig.  /opt is on the btrfs system card,
#     which dArkOS's SD-switch scripts never rewrite (they sed /roms paths,
#     so anything under /roms is a liability).
#   * HW_DEVICE is unconditionally RK356X here, so the connector path is the
#     only path (no sway / no CRTC fallback).
#   * brightness has a floor of 5 — the same floor upstream's 006-display
#     autostart uses — so the menu can never dim the panel to unusable.
#
# Usage:
#   paneladj.sh <brightness|contrast|saturation|hue> <up|down|0-100>
#   paneladj.sh value <brightness|contrast|saturation|hue>   # print current
#   paneladj.sh restore            # re-apply persisted values (boot hook)

CONF=/opt/ngp-panel/panel.conf
HELPER=/opt/ngp-panel/panelprop.py
PY=/usr/bin/python3

MIN=0
MAX=100
PROPS="brightness contrast saturation hue"

prop_min() {
  case "$1" in
    brightness) echo 5 ;;   # upstream autostart floor: never unusably dark
    *)          echo 0 ;;
  esac
}

clamp() { # $1=prop $2=value -> echoes clamped value
  local v="$2" lo
  [[ "$v" =~ ^[0-9]+$ ]] || v=50
  [ "$v" -gt "$MAX" ] && v=$MAX
  lo=$(prop_min "$1")
  [ "$v" -lt "$lo" ] && v=$lo
  echo "$v"
}

conf_get() { # $1=prop -> echoes persisted value or empty
  [ -f "$CONF" ] || return 0
  grep -E "^$1=" "$CONF" 2>/dev/null | tail -1 | cut -d= -f2
}

hw_get() { # $1=prop -> echoes live connector value or empty
  $PY "$HELPER" get "$1" 2>/dev/null | awk '{print $NF}'
}

hw_set() { # $1=prop $2=value -> 0 on success
  $PY "$HELPER" set "$1" "$2" >/dev/null 2>&1
}

# Current effective value: persisted setting, else live hardware, else 50.
get_value() {
  local p="$1" v
  v="$(conf_get "$p")"
  [[ "$v" =~ ^[0-9]+$ ]] || v="$(hw_get "$p")"
  [[ "$v" =~ ^[0-9]+$ ]] || v=50
  clamp "$p" "$v"
}

write_conf() { # uses BRIGHTNESS/CONTRAST/SATURATION/HUE from the caller
  cat > "$CONF" <<EOF
# NGP45HT panel BCSH settings — 0-100, 50 = neutral (driver default).
# Written by paneladj.sh; applied to hardware by ngp-panel-restore.service
# at every boot (DRM connector properties reset on reboot).
brightness=$BRIGHTNESS
contrast=$CONTRAST
saturation=$SATURATION
hue=$HUE
EOF
}

set_value() { # $1=prop $2=value
  local p="$1" v
  v="$(clamp "$p" "$2")"
  if ! hw_set "$p" "$v"; then
    echo "ERROR: failed to set $p=$v"
    exit 1
  fi
  BRIGHTNESS="$(get_value brightness)"
  CONTRAST="$(get_value contrast)"
  SATURATION="$(get_value saturation)"
  HUE="$(get_value hue)"
  case "$p" in
    brightness) BRIGHTNESS="$v" ;;
    contrast)   CONTRAST="$v" ;;
    saturation) SATURATION="$v" ;;
    hue)        HUE="$v" ;;
  esac
  write_conf
}

step_up()   { set_value "$1" "$(( $(get_value "$1") + 1 ))"; }
step_down() { set_value "$1" "$(( $(get_value "$1") - 1 ))"; }

restore() {
  local p
  for p in $PROPS; do
    hw_set "$p" "$(get_value "$p")"
  done
}

case "${1:-}" in
  brightness|contrast|saturation|hue)
    case "${2:-}" in
      up)      step_up "$1" ;;
      down)    step_down "$1" ;;
      restore) restore ;;
      "")      echo "ERROR: missing value for $1"; exit 1 ;;
      *)       set_value "$1" "$2" ;;
    esac
    ;;
  value)
    [ -n "${2:-}" ] || { echo "ERROR: value needs a property"; exit 1; }
    get_value "$2"
    ;;
  values)
    # all four at once (pure bash while panel.conf exists — no python spawn),
    # for the dialog front-end to refresh its display in one shot
    echo "BRIGHTNESS=$(get_value brightness)"
    echo "CONTRAST=$(get_value contrast)"
    echo "SATURATION=$(get_value saturation)"
    echo "HUE=$(get_value hue)"
    ;;
  restore)
    restore
    ;;
  *)
    echo "usage: paneladj.sh <brightness|contrast|saturation|hue> <up|down|0-100>"
    echo "       paneladj.sh value <property>"
    echo "       paneladj.sh restore"
    exit 1
    ;;
esac
