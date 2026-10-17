#!/bin/bash
# ngp-rompool.sh -- present both TF cards as ONE /roms tree (Batocera-style mergerfs pool),
# so dArkOS needs no more "Switch to SD2 / Main SD for Roms" runs.
#
# Layout after this runs:
#   /mnt/roms1  = TF1 exFAT  (system card ROM partition, mmcblk1p5)
#   /mnt/roms2  = TF2 vfat   (second card, mmcblk2p1) -- optional, absent is fine
#   /roms       = mergerfs union of the two; every dArkOS path keeps working unchanged
#   /roms2      = bind of the TF2 branch, so old scripts that poke /roms2 still see it
#
# Kernel overlayfs cannot be used here: it refuses FAT/exFAT as any layer
# ("overlayfs: filesystem on '...' not supported"), which is why Batocera uses mergerfs.
#
#   ngp-rompool.sh install   write fstab + fallback unit + guard the switch scripts
#   ngp-rompool.sh merge     mount branches + pool now (no reboot)
#   ngp-rompool.sh status    what is mounted where, and which card each system comes from
#   ngp-rompool.sh revert    restore the original fstab and mount TF1 straight at /roms

set -u
B1=/dev/mmcblk1p5
B2=/dev/mmcblk2p1
M1=/mnt/roms1
M2=/mnt/roms2
POOL=/roms
FS=/etc/fstab
MOPTS="allow_other,use_ino,inodecalc=path-hash,category.create=epff,func.getattr=ff,cache.files=partial,dropcacheonclose=true,moveonenospc=true,minfreespace=4G"

need_root() { [ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }; }

install() {
  need_root
  [ -f "$FS.orig-ngp" ] || cp -a "$FS" "$FS.orig-ngp"
  mkdir -p "$M1" "$M2" /roms2
  grep -aq "^user_allow_other" /etc/fuse.conf 2>/dev/null || echo "user_allow_other" >> /etc/fuse.conf
  command -v mergerfs >/dev/null || { echo "mergerfs not installed"; exit 1; }

  cat > "$FS" <<EOF
/dev/mmcblk1p4  /  btrfs defaults,noatime,compress=zstd:1,ssd_spread 0 0

/dev/mmcblk1p3 /boot vfat defaults,noatime 0 0
# NGP45HT: both cards are branches of one mergerfs pool at /roms (ngp-rompool.sh).
# TF1 must exist; TF2 is nofail so the pool still comes up with one card.
$B1 $M1 exfat defaults,auto,umask=000,uid=1000,gid=1000,noatime,nofail 0 0
$B2 $M2 vfat defaults,auto,umask=0000,iocharset=utf8,uid=1000,gid=1000,noatime,nofail,x-systemd.device-timeout=7 0 0
$M1:$M2 $POOL fuse.mergerfs defaults,$MOPTS,nofail,x-systemd.requires=mnt-roms1.mount 0 0
$M2 /roms2 none nofail,bind,x-systemd.requires=mnt-roms2.mount 0 0
$POOL/tools /opt/system/Tools none nofail,x-systemd.device-timeout=7,bind,x-systemd.requires=roms.mount 0 0
# No swap entry here.  The NGP45HT has no partition labelled "swap" (its
# by-partlabel directory holds boot, dArkOS_Fat, emuelec, resource, rootfs,
# storage, uboot), so a PARTLABEL=swap line - copy-pasted from the rg43h
# fstab - made systemd-fstab-generator emit dev-disk-by\x2dpartlabel-swap.device
# and wait the full 90 s DefaultDeviceTimeoutSec on every single boot.
# Swap comes from zram instead (finishing_touches-rk3562.sh, priority 100).
EOF

  cat > /usr/local/sbin/ngp-roms-fallback.sh <<'SH'
#!/bin/bash
# If the mergerfs pool failed to come up, never leave ES without its ROMs:
# mount TF1 straight at /roms and say so loudly.
logger -t ngp-rompool "pool absent at /roms -- falling back to TF1 only"
echo "ngp-rompool: pool missing, mounting TF1 directly at /roms" >> /var/log/ngp-rompool.log 2>&1
mount /dev/mmcblk1p5 /roms || logger -t ngp-rompool "fallback mount FAILED"
SH
  chmod 755 /usr/local/sbin/ngp-roms-fallback.sh
  cat > /etc/systemd/system/ngp-roms-fallback.service <<'UNIT'
[Unit]
Description=NGP45HT ROM pool fallback (mount TF1 at /roms if mergerfs failed)
After=local-fs.target remote-fs.target systemd-tmpfiles-setup.service
ConditionPathIsMountPoint=!/roms
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ngp-roms-fallback.sh

[Install]
WantedBy=local-fs.target
UNIT
  systemctl daemon-reload
  systemctl enable ngp-roms-fallback.service >/dev/null 2>&1

  # The two dArkOS switch scripts would mount a card OVER the pool and sed every
  # /roms path in the configs, so refuse to run while the pool is active.
  for f in "/opt/system/Advanced/Switch to SD2 for Roms.sh" "/opt/system/Advanced/Switch to Main SD for Roms.sh"; do
    [ -f "$f" ] || continue
    [ -f "$f.orig-ngp" ] || cp -a "$f" "$f.orig-ngp"
    grep -q "ngp-rompool guard" "$f" && continue
    { echo '#!/bin/bash'
      echo '# ngp-rompool guard: both cards are already merged into /roms (see ngp-rompool.sh).'
      echo 'if mount | grep -q " /roms .*mergerfs"; then'
      echo '  echo "Both TF cards are already merged at /roms -- switching is not needed."'
      echo '  echo "To go back to the old single-card behaviour: sudo ngp-rompool.sh revert"'
      echo '  read -r -p "Press Enter to close" _; exit 0'
      echo 'fi'
      if head -1 "$f.orig-ngp" | grep -q "^#!"; then tail -n +2 "$f.orig-ngp"; else cat "$f.orig-ngp"; fi
    } > "$f"
    chmod 755 "$f"
    echo "  guarded: $f"
  done
  echo "installed. now run:  ngp-rompool.sh merge   (or reboot)"
}

merge() {
  need_root
  mountpoint -q "$POOL" && grep -q mergerfs /proc/mounts && { echo "pool already up"; status; exit 0; }
  umount /opt/system/Tools 2>/dev/null
  umount -l "$POOL" 2>/dev/null
  mountpoint -q "$M1" || mount "$B1" "$M1" || { echo "TF1 branch mount failed"; exit 1; }
  if [ -b "$B2" ]; then mountpoint -q "$M2" || mount "$B2" "$M2" || echo "  TF2 present but mount failed; continuing with TF1 only"; else echo "  TF2 absent ($B2 not a block device); pool will have one branch"; fi
  mergerfs -o "$MOPTS" "$M1:$M2" "$POOL" || { echo "mergerfs failed"; exit 1; }
  mountpoint -q "$M2" && { mountpoint -q /roms2 || mount --bind "$M2" /roms2; }
  [ -d "$POOL/tools" ] && { mountpoint -q /opt/system/Tools || mount --bind "$POOL/tools" /opt/system/Tools; }
  status
}

status() {
  echo "== mounts =="
  grep -aE " /roms | /roms2 | /mnt/roms[12] | /opt/system/Tools " /proc/mounts | sed 's/,iocharset.*//;s/,allow_utime.*//'
  echo "== what the union shows =="
  printf "  %-14s %s\n" "top-level dirs" "$(ls "$POOL" 2>/dev/null | wc -l)"
  for s in fbneo gba cps1 ports bios tools; do
    a=$(ls "$M1/$s" 2>/dev/null | wc -l); b=$(ls "$M2/$s" 2>/dev/null | wc -l); u=$(ls "$POOL/$s" 2>/dev/null | wc -l)
    printf "  %-8s TF1=%-6s TF2=%-6s union=%-6s %s\n" "$s" "$a" "$b" "$u" \
      "$([ "$u" -ge $(( a > b ? a : b )) ] && echo ok || echo 'CHECK')"
  done
  echo "== writes land where =="
  t="$POOL/__ngp_write_probe"; echo x > "$t" 2>/dev/null && sync
  echo "  on TF1: $([ -e "$M1/__ngp_write_probe" ] && echo yes || echo no)  on TF2: $([ -e "$M2/__ngp_write_probe" ] && echo yes || echo no)"
  rm -f "$t" "$M1/__ngp_write_probe" "$M2/__ngp_write_probe" 2>/dev/null
  echo "== fallback unit =="
  systemctl is-enabled ngp-roms-fallback.service 2>&1
}

revert() {
  need_root
  [ -f "$FS.orig-ngp" ] || { echo "no fstab backup"; exit 1; }
  cp -a "$FS.orig-ngp" "$FS"
  systemctl disable ngp-roms-fallback.service >/dev/null 2>&1
  umount /opt/system/Tools 2>/dev/null; umount /roms2 2>/dev/null
  umount "$POOL" 2>/dev/null || umount -l "$POOL" 2>/dev/null
  umount "$M2" 2>/dev/null; umount "$M1" 2>/dev/null
  systemctl daemon-reload
  mount "$B1" "$POOL" && mount --bind "$POOL/tools" /opt/system/Tools
  for f in "/opt/system/Advanced/Switch to SD2 for Roms.sh" "/opt/system/Advanced/Switch to Main SD for Roms.sh"; do
    [ -f "$f.orig-ngp" ] && cp -a "$f.orig-ngp" "$f"
  done
  echo "reverted to the original single-card layout"; status
}

case "${1:-status}" in
  install) install ;;
  merge) merge ;;
  status) status ;;
  revert) revert ;;
  *) sed -n '2,18p' "$0" ;;
esac
