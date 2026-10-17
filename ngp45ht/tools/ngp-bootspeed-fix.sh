#!/bin/bash
# ngp-bootspeed-fix.sh — remove the 90-second boot stall on the NGP45HT.
#
# Symptom: `systemd-analyze` reports about 1 min 41 s to reach multi-user.target
# (kernel ~4.8 s, userspace ~1 min 36 s) even though `systemd-analyze blame`
# adds up to barely 20 s of real work.  The missing ~90 s is a device-unit
# timeout: systemd sat waiting for a device that does not exist.
#
# Cause (measured, see CHANGELOG 2026-10-17):
#   /etc/fstab carried  "PARTLABEL=swap none swap sw,pri=10 0 0", copied from
#   the rg43h fstab.  This device has no partition labelled "swap" - its
#   /dev/disk/by-partlabel holds boot, dArkOS_Fat, emuelec, resource, rootfs,
#   storage, uboot.  systemd-fstab-generator turned that line into
#   dev-disk-by\x2dpartlabel-swap.device, put it in swap.target, and
#   tmp.mount (which is After=swap.target) then waited the full
#   DefaultDeviceTimeoutSec = 90 s.  Evidence: critical-chain before the fix
#   showed tmp.mount @1min30.891s; after it, swap.target @1.146s.
#
# Second, latent: ngp-panel-restore.service had Wants=dev-dri-card0.device.
# Wants= makes systemd create a real job for the device unit, so a slow DRM
# bind would have cost another 90 s.  It did not fire in the measured boot
# (blame showed 2.748 s, because the unit sits in multi-user.target and card0
# was long since up), but it is the same class of trap, so it goes too; the
# unconditional `sleep 2` it used is replaced by a bounded poll.
#
# This script is idempotent - run it as many times as you like.
#
#   sudo ngp-bootspeed-fix.sh          # fix the running system
#   sudo ngp-bootspeed-fix.sh --check  # report only, change nothing

set -u
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

SRC="$(cd "$(dirname "$0")" && pwd)"
FSTAB=/etc/fstab
PANEL_UNIT=/etc/systemd/system/ngp-panel-restore.service
GOOD_PANEL="$SRC/ngp-panel/ngp-panel-restore.service"
CHANGED=0

say()  { printf '%s\n' "$*"; }
do_it() { if [ "$CHECK" = 1 ]; then printf '  [would run] %s\n' "$*"; else "$@"; fi; }

if [ "$CHECK" = 0 ] && [ "$(id -u)" -ne 0 ]; then
  echo "run as root (sudo $0)" >&2
  exit 1
fi

# ---------------------------------------------------------------- fstab ----
# Comment out every swap line whose device cannot be resolved.  A swap entry
# that points at something real (zram, a partition that exists) is left alone.
say "== /etc/fstab swap entries =="
STALE=()
mapfile -t LINES < "$FSTAB"
for line in "${LINES[@]}"; do
  case "$line" in
    ''|'#'*|[[:space:]]'#'*) continue ;;
  esac
  [ "$(printf '%s' "$line" | awk '{print $3}')" = "swap" ] || continue
  spec=$(printf '%s' "$line" | awk '{print $1}')
  if [ -e "$spec" ] || [ -b "$spec" ] || blkid "$spec" >/dev/null 2>&1; then
    say "  keep    $spec (resolves)"
    continue
  fi
  say "  STALE   $spec  -> no such device, this is the 90 s stall"
  STALE+=("$spec")
done

if [ "${#STALE[@]}" -gt 0 ]; then
  CHANGED=1
  if [ "$CHECK" = 1 ]; then
    say "  [would comment out ${#STALE[@]} line(s), backup to ${FSTAB}.bak-bootspeed-*]"
  else
    cp -a "$FSTAB" "${FSTAB}.bak-bootspeed-$(date +%Y%m%d-%H%M%S)"
    for s in "${STALE[@]}"; do
      awk -v s="$s" '
        $3 == "swap" && $1 == s && $0 !~ /^[[:space:]]*#/ {
          print "#" $0
          print "#   ^ disabled by ngp-bootspeed-fix.sh " strftime("%Y-%m-%d") ": no such device,"
          print "#     so systemd waited the full 90 s DefaultDeviceTimeoutSec at every boot."
          print "#     Swap now comes from zram-swap.service."
          next
        }
        { print }
      ' "$FSTAB" > "${FSTAB}.new" && mv "${FSTAB}.new" "$FSTAB"
    done
    say "  commented out ${#STALE[@]} line(s); backup: $(ls -t ${FSTAB}.bak-bootspeed-* 2>/dev/null | head -1)"
  fi
fi

# ----------------------------------------------------------------- zram ----
# Swap was wanted, just not from a partition that isn't there.  zram gives it
# back with nothing to wait for at boot.
say "== swap =="
if [ -x /usr/local/sbin/zram-swap ]; then
  say "  upstream /usr/local/sbin/zram-swap present (image >= v1.1)"
  if [ "$CHECK" = 0 ]; then
    systemctl enable zram-swap.service 2>&1 | sed 's/^/  /'
    systemctl start zram-swap.service 2>&1 | sed 's/^/  /'
  else
    do_it systemctl enable zram-swap.service
  fi
else
  say "  no upstream zram-swap (image predates v1.1) - installing fallback unit"
  if [ "$CHECK" = 0 ]; then
    if [ -f "$SRC/zram-swap.service" ]; then
      install -D -m 0644 "$SRC/zram-swap.service" /etc/systemd/system/zram-swap.service
    else
      # shipped on its own (tools zip, pasted into a terminal): inline the unit
      cat > /etc/systemd/system/zram-swap.service <<'ZUNIT'
[Unit]
Description=Compressed swap in RAM (zram) - NGP45HT fallback
DefaultDependencies=no
After=systemd-modules-load.service
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo zstd > /sys/block/zram0/comp_algorithm; echo 536870912 > /sys/block/zram0/disksize; /sbin/mkswap -L zram0 /dev/zram0 >/dev/null; /sbin/swapon -p 10 /dev/zram0'
ExecStop=/bin/sh -c '/sbin/swapoff /dev/zram0 >/dev/null 2>&1 || true; echo 1 > /sys/block/zram0/reset'

[Install]
WantedBy=swap.target
ZUNIT
    fi
    systemctl enable zram-swap.service 2>&1 | sed 's/^/  /'
    systemctl start zram-swap.service 2>&1 | sed 's/^/  /'
  else
    printf '  [would run] install zram-swap.service -> /etc/systemd/system/\n'
  fi
  CHANGED=1
fi

# --------------------------------------------------- panel restore unit ----
say "== ngp-panel-restore.service =="
if grep -qs "^Wants=.*\.device" "$PANEL_UNIT" 2>/dev/null; then
  say "  has Wants=<device> - the second 90 s trap"
  CHANGED=1
  if [ "$CHECK" = 0 ]; then
    if [ -f "$GOOD_PANEL" ]; then
      install -D -m 0644 "$GOOD_PANEL" "$PANEL_UNIT"
      say "  replaced with $GOOD_PANEL"
    else
      # no known-good copy next to this script: do the surgery inline
      cat > "$PANEL_UNIT" <<'UNIT'
[Unit]
Description=NGP45HT panel colour restore (VOP2 BCSH brightness/contrast/saturation/hue)
After=systemd-modules-load.service

[Service]
Type=oneshot
ExecStartPre=/bin/sh -c 'i=0; while [ ! -c /dev/dri/card0 ] && [ $i -lt 30 ]; do sleep 0.2; i=$((i+1)); done; exit 0'
ExecStart=/opt/ngp-panel/paneladj.sh restore
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
      say "  rewritten in place (no Wants= on a device unit, bounded card0 wait)"
    fi
  fi
else
  say "  ok (no Wants= on a device unit)"
fi

# ------------------------------------------------------------ emmc-swap ----
# This device's eMMC has no partition labelled "swap", so emmc-swap.service
# only wakes up, finds nothing and exits - while dragging in
# Wants=systemd-udev-settle.service (~1.9 s) for the privilege.
say "== emmc-swap.service =="
if [ ! -e /dev/disk/by-partlabel/swap ] &&
   systemctl list-unit-files emmc-swap.service 2>/dev/null | grep -q emmc-swap; then
  say "  no swap partition here - disabling (upstream v1.1 enables it unconditionally)"
  do_it systemctl disable emmc-swap.service
  CHANGED=1
else
  say "  ok"
fi

# ----------------------------------------------------------------- done ----
if [ "$CHECK" = 0 ]; then
  systemctl daemon-reload
  say ""
  say "== /proc/swaps =="
  cat /proc/swaps | sed 's/^/  /'
  if [ "$CHANGED" = 1 ]; then
    say ""
    say "Reboot, then:  systemd-analyze time"
    say "Expected:      ~12 s total (kernel ~5 s + userspace ~7.5 s)"
  else
    say ""
    say "Nothing left to fix - this system was already clean."
  fi
fi
