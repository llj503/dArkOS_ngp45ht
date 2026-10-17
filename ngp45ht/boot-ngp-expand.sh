#!/bin/bash
# ngp-expand.sh -- NGP45HT first boot: give EASYROMS (p5) the whole rest of the
# card, format it exFAT and populate /roms.
#
# Installed as /boot/ngp-expand.sh and called from /boot/firstboot.sh.
#
# Deliberately NOT a copy of dArkOS's scripts/expandtoexfat.sh.rk3562:
#
#   * Upstream also runs `growpart` on partition 4 (the btrfs rootfs) to leave
#     ~11 GB of slack "for future update needs".  On this port p4 has to stay
#     exactly 12,629,049,344 bytes, because that is the geometry the published
#     image is cut to: a grown p4 makes the running card impossible to re-clone
#     into a 12 GiB image.  ROMS gets everything that is left instead, which is
#     what people actually want anyway (p4 is 11.76 GiB with ~2.5 GiB used).
#   * Upstream finishes with `cp /boot/fstab.exfat /etc/fstab`, which would
#     throw the dual-card mergerfs pool away.  The fstab is regenerated through
#     ngp-rompool.sh instead, so both TF slots keep working.
#   * Upstream drives a dialog gauge on /dev/tty1 and reboots at the end.
#     Everything here is logged to /boot/ngp-firstboot.log (readable from a PC
#     on the FAT partition, no rootfs mount needed) and the ROM pool is brought
#     up in place, so EmulationStation -- which systemd orders After=firstboot
#     -- starts on a working /roms without needing a second boot.
#
# "Already expanded" is decided from the partition itself (p5 >= 1 GiB), never
# from a marker file: this script ships *inside* the image, so any marker would
# be cloned along with it and every end user would then skip the expansion they
# need.  The one exception is the reboot-retry counter, which lives on /boot and
# must be deleted before cloning (see ngp45ht/README.md).
set -u

# Two logs: /boot is convenient (readable from a PC on the FAT partition) but
# /var/log is the one that is guaranteed to be writable, and both can be read
# offline with ngp45ht/tools/btrfsls.py --cat.
L1=/boot/ngp-firstboot.log
L2=/var/log/ngp-firstboot.log
RETRY=/boot/ngp-expand.retries

say() {
	printf '[%s] expand: %s\n' "$(date '+%H:%M:%S')" "$*" >> "$L1" 2>/dev/null
	printf '[%s] expand: %s\n' "$(date '+%H:%M:%S')" "$*" >> "$L2" 2>/dev/null
	printf 'ngp-expand: %s\n' "$*" > /dev/tty1 2>/dev/null
	echo "$*"
}

# --- fast path -------------------------------------------------------------
# This script ships inside the image and firstboot.service stays enabled (that
# is what makes an end user's first boot grow /roms), so it runs on every boot.
# Re-mounting and re-merging every boot would churn the mounts for nothing, so
# leave as soon as the previous run finished.
#
# The sentinel deliberately lives *on /roms* and not in /etc or /boot: those are
# part of the image, so a marker there would be cloned and every end user would
# skip the expansion.  p5 is not cloned, so a fresh flash never has it.  It is
# also only written at the very end, so a run cut short by systemd's 90 s
# TimeoutStartSec is simply retried on the next boot instead of being mistaken
# for success (a half-copied /roms/themes would otherwise look "populated").
OK=/roms/.ngp-expand-ok
if mountpoint -q /roms 2>/dev/null && [ -f "$OK" ]; then
	say "/roms already mounted and marked done -- nothing to do"
	exit 0
fi

# --- which disk are we even on --------------------------------------------
ROOTSRC=$(findmnt -n -o SOURCE / 2>/dev/null | head -1)
[ -n "$ROOTSRC" ] || ROOTSRC=/dev/mmcblk1p4
DISK=/dev/$(printf '%s' "${ROOTSRC#/dev/}" | sed 's/p[0-9]*$//')
PART=${DISK}p5

sz() { lsblk -bndo SIZE "$1" 2>/dev/null | head -1; }

say "root=$ROOTSRC disk=$DISK p5=$PART"
S=$(sz "$PART"); S=${S:-0}
say "p5 size=$S bytes ($((S / 1048576)) MiB)"

# --- 1. (re)create p5 over all the free space after p4 ---------------------
if [ "$S" -lt 1073741824 ]; then
	say "p5 is smaller than 1 GiB -- recreating it over the whole free area"
	/sbin/wipefs -a "$PART" >/dev/null 2>&1
	# Every fdisk call is behind `timeout 10`: an fdisk that stops on a question
	# nobody answers ("remove the signature?") would otherwise eat the whole
	# 90 s systemd budget -- that is exactly what silently killed the
	# 2026-10-17 run.  The "y" answers that prompt; when there is no prompt it
	# is merely an unknown command and t/5/11/w still run.
	printf 'd\n5\nw\n' | timeout 10 /sbin/fdisk "$DISK" >/dev/null 2>&1
	say "  fdisk delete -> $?"
	printf 'n\n5\n\n\ny\nt\n5\n11\nw\n' | timeout 10 /sbin/fdisk "$DISK" >/dev/null 2>&1
	say "  fdisk create -> $?"
	timeout 10 /sbin/partprobe "$DISK" >/dev/null 2>&1
	timeout 10 /sbin/partx -u "$DISK" >/dev/null 2>&1
	timeout 10 udevadm settle -t 5 >/dev/null 2>&1 || true
	sleep 1
	S=$(sz "$PART"); S=${S:-0}
	say "p5 now $S bytes ($((S / 1048576)) MiB)"
	if [ "$S" -lt 1073741824 ]; then
		# The kernel refused to re-read the table (p4 is mounted, so BLKRRPART
		# fails).  A reboot usually fixes it -- but only ever try once, and
		# only if the counter file can actually be written: without a readable
		# counter this would be an infinite reboot loop.
		N=$(cat "$RETRY" 2>/dev/null); N=${N:-0}
		if [ "${N:-0}" -ge 1 ] || ! echo 1 > "$RETRY" 2>/dev/null; then
			say "GIVING UP: p5 is still $((S / 1048576)) MiB and a reboot is not safe to retry."
			say "  /roms stays small; expand it by hand or reflash."
		else
			say "kernel did not pick the new table up -- rebooting once (attempt 1)"
			sync
			/sbin/reboot
			exit 1
		fi
	fi
else
	say "p5 is already $((S / 1073741824)) GiB -- nothing to expand"
fi
rm -f "$RETRY"

# --- 2. unmount whatever already sits on the ROM partition ------------------
# Order matters and 2026-10-17 got it wrong: the first version formatted first
# and unmounted afterwards, so mkfs.exfat was pointed at a partition that was
# still mounted at /roms (systemd's local-fs.target runs before firstboot).
# The result was logged as a bare "mkfs.exfat FAILED" with no reason, and the
# subsequent `mount -t exfat` failed too because the old FAT16 was still there
# -- so the machine came up with no /roms at all.
for m in /roms /mnt/roms1 /mnt/roms2; do
	if mountpoint -q "$m" 2>/dev/null; then
		umount -l "$m" >/dev/null 2>&1 && say "unmounted $m before formatting"
	fi
done

# --- 3. format it ----------------------------------------------------------
FSTYPE=$(lsblk -no FSTYPE "$PART" 2>/dev/null | head -1)
if [ "${FSTYPE:-}" != "exfat" ]; then
	say "formatting $PART as exFAT (was '${FSTYPE:-none}')"
	# -c takes a plain byte count here (exfatprogs does not accept "16K"), and
	# stderr goes to the log: the bare failure on 2026-10-17 was undiagnosable.
	if /sbin/mkfs.exfat -c 16384 -L EASYROMS "$PART" >>"$L2" 2>&1; then
		say "  mkfs.exfat ok"; FSTYPE=exfat
	else
		say "  mkfs.exfat FAILED (see $L2) -- falling back to FAT32"
		if /sbin/mkfs.vfat -F 32 -n EASYROMS "$PART" >>"$L2" 2>&1; then
			say "  mkfs.vfat ok"; FSTYPE=vfat
		else
			say "  mkfs.vfat FAILED too -- giving up (boot continues without /roms)"
			exit 1
		fi
	fi
fi

# --- 4. populate /roms -----------------------------------------------------
mkdir -p /roms
OPTS=umask=000,uid=1000,gid=1000,noatime
# Three tries: with our options, then bare, then letting mount auto-detect.
# A hard -t exfat here is what turned a failed mkfs into a missing /roms.
if mount -t "${FSTYPE:-auto}" -o "$OPTS" "$PART" /roms 2>>"$L2"; then
	:
elif mount -t "${FSTYPE:-auto}" "$PART" /roms 2>>"$L2"; then
	say "mounted without the umask/uid options"
elif mount "$PART" /roms 2>>"$L2"; then
	say "mounted with auto-detected fs type"
else
	say "mount of $PART at /roms FAILED -- giving up (boot continues without /roms)"
	exit 1
fi
say "mounted $PART at /roms"

if [ -f /roms.tar ]; then
	say "extracting /roms.tar (the roms folder skeleton)"
	tar --no-same-permissions --no-same-owner -xf /roms.tar -C / 2>>"$L2" \
		&& say "  roms.tar ok" || say "  roms.tar extraction FAILED"
else
	say "no /roms.tar -- creating a minimal skeleton"
	for d in bios ports tools savestates themes; do mkdir -p "/roms/$d"; done
fi

# The five themes in /tempthemes are ~88 MB.  If the partition never grew,
# /roms is the 79 MiB FAT the image ships and the copy would fill it and half
# fail, leaving ES worse off than before -- so check for room first.
AVAIL=$(df -k /roms 2>/dev/null | awk 'NR==2 {print $4}'); AVAIL=${AVAIL:-0}
say "free space on /roms: ${AVAIL} KiB"
if [ -d /tempthemes ] && [ -n "$(ls -A /tempthemes 2>/dev/null)" ]; then
	mkdir -p /roms/themes
	if [ "$AVAIL" -lt 204800 ]; then
		say "  not enough room on /roms for the themes -- skipping the copy"
	else
		say "copying themes out of /tempthemes into /roms/themes"
		cp -a /tempthemes/. /roms/themes/ 2>>"$L2" \
			&& say "  themes ok: $(ls /roms/themes 2>/dev/null | wc -l) themes" \
			|| say "  theme copy FAILED"
	fi
fi
# Never leave /roms/themes empty: ES with no theme at all is an unstyled menu.
if [ -z "$(ls -A /roms/themes 2>/dev/null)" ] && [ -d /home/ark/.emulationstation/themes ]; then
	say "/roms/themes still empty -- seeding it from the rootfs copy"
	cp -a /home/ark/.emulationstation/themes/. /roms/themes/ 2>>"$L2" || true
fi
sync

# --- 5. fstab + bring the dual-card pool up --------------------------------
if [ -x /usr/local/sbin/ngp-rompool.sh ]; then
	say "regenerating /etc/fstab through ngp-rompool.sh (both TF slots)"
	/usr/local/sbin/ngp-rompool.sh install >>"$L2" 2>&1 && say "  install ok" || say "  install FAILED"
	systemctl daemon-reload
	/usr/local/sbin/ngp-rompool.sh merge >>"$L2" 2>&1 && say "  merge ok" || say "  merge FAILED"
else
	say "ngp-rompool.sh missing -- plain single-card fstab"
	grep -q "^$PART" /etc/fstab 2>/dev/null || \
		echo "$PART /roms ${FSTYPE:-auto} defaults,auto,umask=000,uid=1000,gid=1000,noatime,nofail 0 0" >> /etc/fstab
fi
# ngp-rompool.sh hard-codes exFAT for the TF1 ROM partition.  That is fine when
# step 3 produced exFAT, but if we had to fall back to FAT32 the next boot would
# try to mount it as exFAT, fail, and lose the pool -- so correct the line.
if [ -n "${FSTYPE:-}" ] && [ "$FSTYPE" != exfat ]; then
	awk -v p="$PART" -v t="$FSTYPE" '$1 == p && $3 != t { $3 = t } { print }' \
		/etc/fstab > /etc/fstab.new 2>>"$L2" && mv /etc/fstab.new /etc/fstab && \
		say "fstab: /mnt/roms1 fs type corrected to $FSTYPE"
	systemctl daemon-reload
fi
if ! mountpoint -q /roms; then
	say "pool did not come up -- falling back to $PART straight on /roms"
	mount -t "${FSTYPE:-auto}" -o umask=000,uid=1000,gid=1000,noatime "$PART" /roms 2>>"$L2" \
		|| mount "$PART" /roms 2>>"$L2" || say "  fallback mount FAILED"
fi
grep -aE " /roms | /mnt/roms[12] " /proc/mounts 2>/dev/null | sed "s/^/  /" >> "$L2"
# The sentinel is written only when p5 really is big: otherwise a card stuck on
# the 79 MiB partition would be marked "done" forever and never retried.
P5=$(sz "$PART"); P5=${P5:-0}
if mountpoint -q /roms 2>/dev/null && [ "$P5" -ge 1073741824 ]; then
	: > "$OK" 2>/dev/null || say "could not write $OK (next boot will redo this)"
	say "done: p5 = $((P5 / 1073741824)) GiB, /roms mounted"
else
	say "NOT FINISHED: p5 = $((P5 / 1048576)) MiB or /roms not mounted -- next boot retries"
fi
exit 0
