#!/bin/bash
# NGP45HT: corrections applied before dArkOS's own first-boot expansion step.
# This file is the byte-exact /boot/firstboot.sh of a shipped card
# (see ngp45ht/README.md); keep it in sync when editing.
#
# Idempotent and safe to re-run.  Ordering is deliberate: systemd kills a
# Type=oneshot unit after DefaultTimeoutStartSec (90 s) and the 2026-10-17
# first boot proved that is exactly what happened -- the expensive partition
# work swallowed the whole budget, and everything queued behind it (the WiFi
# cleanup, the version stamp) never ran.  So: every cheap, must-succeed fix
# happens FIRST, and the expansion runs last behind a hard `timeout`.
#
# Logging goes to /boot (readable from a PC on the FAT partition) *and* to
# /var/log (in case /boot is not writable for some reason -- that is also how
# the run can be audited offline without mounting the btrfs rootfs).
set -u
changed=0

# Distro version shown by EmulationStation as "distro version" at the bottom of
# the main menu.  Bump this whenever the image is re-rolled.
DISTRO_VERSION=10182026

L1=/boot/ngp-firstboot.log
L2=/var/log/ngp-firstboot.log
say() {
	printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$L1" 2>/dev/null
	printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$L2" 2>/dev/null
	echo "$*"
}
say "===== firstboot.sh start (pid $$) ====="
say "boot id: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"

# --- audio: PPSSPP was silent ---------------------------------------------
# ppsspp.sh routes the RK817 to the headphone output for .DEVICE = RG43H, but
# on this board the speaker is the codec's own SPK output (amp enable is the
# codec's spk-ctl on GPIO0_A7), so that route mutes the internal speaker.
f=/usr/local/bin/ppsspp.sh
if [ -f "$f" ] && grep -q "Playback Path' HP" "$f"; then
	[ -f "$f.ngpbak" ] || cp -a "$f" "$f.ngpbak"
	sed -i "s/Playback Path' HP/Playback Path' SPK/" "$f"
	say "ppsspp.sh: Playback Path HP -> SPK"
	changed=1
fi

# --- input: L2/R2 are GPIO switches here ----------------------------------
for c in /home/ark/.config/retroarch/retroarch.cfg /home/ark/.config/retroarch32/retroarch.cfg; do
	[ -f "$c" ] || continue
	if ! grep -q 'input_player1_l2_btn *= *"6"' "$c"; then
		[ -f "$c.ngpbak" ] || cp -a "$c" "$c.ngpbak"
		sed -i \
			-e 's/^input_player1_l2_axis *=.*/input_player1_l2_axis = "nul"/' \
			-e 's/^input_player1_r2_axis *=.*/input_player1_r2_axis = "nul"/' "$c"
		grep -q '^input_player1_l2_axis' "$c" || echo 'input_player1_l2_axis = "nul"' >> "$c"
		grep -q '^input_player1_r2_axis' "$c" || echo 'input_player1_r2_axis = "nul"' >> "$c"
		echo 'input_player1_l2_btn = "6"' >> "$c"
		echo 'input_player1_r2_btn = "7"' >> "$c"
		say "$(basename "$(dirname "$c")")/retroarch.cfg: l2/r2 -> btn 6/7, axes nulled"
		changed=1
	fi
done

# --- input: PPSSPP standalone has the left stick Y flipped ------------------
# PPSSPP keeps its own mapping in controls.ini; it has no equivalent of
# RetroArch's signed axis, so it inherits whatever polarity the shipped file
# assumed.  On this board the analog axes are standard (the RetroArch
# autoconfig for rk3562-joystick binds l_y_minus_axis = "-1", i.e. up is
# negative, and that works), so the shipped An.Up/An.Down pair is the wrong way
# round and pushing up moves down.
#
# /home/ark/.config/ppsspp is only a symlink -- ppsspp.sh points it at
# /<roms>/psp/ppsspp -- so the live file lives on the ROMS partition.  Patch the
# /opt template too, otherwise a fresh ROMS folder just re-seeds the bug.
# Guard is value-based, so a hand-edited mapping is never touched twice.
for ci in /opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM/controls.ini \
		/roms/psp/ppsspp/PSP/SYSTEM/controls.ini \
		/roms2/psp/ppsspp/PSP/SYSTEM/controls.ini \
		/home/ark/.config/ppsspp/PSP/SYSTEM/controls.ini; do
	[ -f "$ci" ] || continue
	grep -q '^An\.Up *= *10-4003' "$ci" || continue
	sed -i -e 's/^An\.Up *= *10-4003/An.Up = 10-4002/' \
		-e 's/^An\.Down *= *10-4002/An.Down = 10-4003/' "$ci"
	say "ppsspp controls.ini: An.Up/An.Down swapped -> $(sed -n 's/^An\.\(Up\|Down\).*/&/p' "$ci" | tr '\n' ' ') ($ci)"
	changed=1
done

# --- build stamp ------------------------------------------------------------
V=/home/ark/.config/.VERSION
if [ "$(cat "$V" 2>/dev/null)" != "$DISTRO_VERSION" ]; then
	echo "$DISTRO_VERSION" > "$V"
	chown ark:ark "$V" 2>/dev/null || true
	say "VERSION -> $DISTRO_VERSION"
	changed=1
fi

# ES 的「Distro Version」其实不是读 .VERSION：GuiMenu::addVersionInfo() 执行的是
#   cat /usr/share/plymouth/themes/text.plymouth | grep title | cut -c 7-50
# 所以这里必须同步 plymouth 的 title，否则界面上永远是镜像构建那天的日期。
PLY=/usr/share/plymouth/themes/text.plymouth
if [ -f "$PLY" ] && ! grep -q "title=.*($DISTRO_VERSION)" "$PLY"; then
	sed -i "s/^title=.*/title=dArkOS ($DISTRO_VERSION)/" "$PLY"
	say "plymouth title -> dArkOS ($DISTRO_VERSION)"
	changed=1
fi

# --- EmulationStation theme -------------------------------------------------
# es_settings.cfg usually names es-theme-nes-box, which only ever exists under
# /roms/themes -- empty until the expansion below populates it, so a freshly
# flashed card boots with no theme at all.  Point at a theme that lives in the
# rootfs instead: that one survives both cloning and a failed expansion.
CFG=/home/ark/.emulationstation/es_settings.cfg
if [ -f "$CFG" ]; then
	CUR=$(grep -o 'name="ThemeSet" value="[^"]*"' "$CFG" 2>/dev/null | sed 's/.*value="//;s/"$//')
	if [ -n "${CUR:-}" ] && [ ! -d "/home/ark/.emulationstation/themes/$CUR" ]; then
		FALL=$(ls /home/ark/.emulationstation/themes 2>/dev/null | head -1)
		if [ -n "${FALL:-}" ]; then
			sed -i "s/name=\"ThemeSet\" value=\"[^\"]*\"/name=\"ThemeSet\" value=\"$FALL\"/" "$CFG"
			chown ark:ark "$CFG" 2>/dev/null || true
			say "es_settings.cfg: ThemeSet $CUR -> $FALL (not present anywhere)"
			changed=1
		fi
	fi
	say "es_settings.cfg ThemeSet now: $(grep -o 'name="ThemeSet" value="[^"]*"' "$CFG" 2>/dev/null)"
fi

# --- boot speed: never wait on a swap device that does not exist -------------
# "PARTLABEL=swap none swap sw,pri=10 0 0" was copy-pasted from the rg43h fstab.
# This device has no partition labelled swap, so systemd-fstab-generator emits
# dev-disk-by\x2dpartlabel-swap.device and the boot stalls for the full 90 s
# DefaultDeviceTimeoutSec.  It came back on 2026-10-17 (the earlier fix only
# added an explanatory comment above the live line), so enforce it here.
if [ -f /etc/fstab ] && grep -qE '^[^#]*[[:space:]]swap[[:space:]]' /etc/fstab; then
	cp -a /etc/fstab "/etc/fstab.bak-ngpfirstboot-$(date +%Y%m%d-%H%M%S)" 2>/dev/null
	awk '$3 == "swap" && $0 !~ /^[[:space:]]*#/ {
	       print "# ngp-firstboot: " $0
	       print "#   disabled: no such device exists on this board, and systemd waited"
	       print "#   the full 90 s DefaultDeviceTimeoutSec for it at every boot."
	       print "#   Swap comes from zram-swap.service instead."
	       next
	     }
	     { print }' /etc/fstab > /etc/fstab.new && mv /etc/fstab.new /etc/fstab
	say "fstab: commented out unresolvable swap line(s)"
	systemctl daemon-reload 2>/dev/null
	swapon -a 2>/dev/null
	changed=1
fi
systemctl is-enabled zram-swap.service >/dev/null 2>&1 || systemctl enable zram-swap.service 2>/dev/null

# --- remote access: SSH on, and still on after the next reboot --------------
# /opt/system/Enable Remote Services.sh only does `systemctl start ssh.service`
# -- its `systemctl enable ssh` line is commented out upstream -- so SSH dies
# with every reboot and the Options entry has to be toggled again by hand.
# Force the unit enabled here (idempotent) and make sure it really listens.
port22() {
	if command -v ss >/dev/null 2>&1; then
		ss -ltn 2>/dev/null | grep -q '[:.]22[ ]'
		return
	fi
	awk 'NR>1 && $2 ~ /:0016$/ && $4 == "0A" { f = 1 } END { exit !f }' \
		/proc/net/tcp /proc/net/tcp6 2>/dev/null
}
if ! systemctl is-enabled ssh.service >/dev/null 2>&1; then
	systemctl unmask ssh.service 2>/dev/null
	systemctl enable ssh.service >/dev/null 2>&1
	say "ssh.service enabled -> $(systemctl is-enabled ssh.service 2>&1)"
	changed=1
fi
mkdir -p /run/sshd
ssh-keygen -A >/dev/null 2>&1
# start, not restart: `restart` would drop the SSH session this script is
# being run over when it is invoked by hand.
systemctl is-active ssh.service >/dev/null 2>&1 || systemctl start ssh.service >/dev/null 2>&1
i=0
while [ $i -lt 10 ] && ! port22; do i=$((i + 1)); sleep 1; done
if port22; then
	say "ssh listening on :22 (enabled=$(systemctl is-enabled ssh.service 2>&1) active=$(systemctl is-active ssh.service 2>&1))"
else
	say "ssh NOT listening -- falling back to /usr/sbin/sshd directly"
	/usr/sbin/sshd >/dev/null 2>&1
	sleep 2
	if port22; then
		say "sshd fallback listening"
	else
		say "sshd fallback FAILED: $(systemctl status ssh.service 2>&1 | tr '\n' '|' | cut -c1-300)"
	fi
fi

# --- hygiene: the shipped base image carries real secrets -------------------
# Its /etc/ssh/ssh_host_*_key were generated once by the image build, so every
# card flashed from it shares the same host keys, and /etc/hostapd/hostapd.conf
# still holds the upstream author's AP passphrase.
#
# The marker lives on /boot on purpose: an /etc marker would be cloned into the
# next image, and then every card flashed from it would silently skip this
# step.  Delete /boot/ngp45ht-hygiene.done before cloning a card.
HYG=/boot/ngp45ht-hygiene.done
if [ ! -f "$HYG" ]; then
	if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
		rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
		ssh-keygen -A >/dev/null 2>&1
		say "ssh host keys regenerated"
	fi
	h=/etc/hostapd/hostapd.conf
	if [ -f "$h" ] && grep -q "^ssid=ArkOS_AP_fbneo" "$h"; then
		sed -i -e 's/^ssid=.*/ssid=ArkOS_AP/' \
			-e 's/^wpa_passphrase=.*/wpa_passphrase=darkos0000/' "$h"
		say "hostapd AP defaults neutralised"
	fi
	[ -f "$HYG" ] || echo done > "$HYG" 2>/dev/null
	say "hygiene marker: $([ -f "$HYG" ] && echo written || echo 'WRITE FAILED')"
fi

# --- EASYROMS: give p5 the rest of the card, format exFAT, fill /roms ------
# Last, and behind a hard timeout: systemd kills this unit at 90 s, and the
# 2026-10-17 run lost the whole budget here.  Everything above is already done
# by this point, so a failure only costs the ROM partition -- and the sentinel
# in /roms makes the next boot retry it.
if [ -f /boot/ngp-expand.sh ]; then
	say "running /boot/ngp-expand.sh (timeout 60)"
	timeout 60 sh /boot/ngp-expand.sh
	say "ngp-expand.sh returned $?"
else
	say "/boot/ngp-expand.sh missing -- /roms was not expanded"
fi

# --- privacy: no Wi-Fi credentials may survive into a published image -------
# Profiles in /etc/NetworkManager/system-connections hold the PSK in clear
# text, and the image is cloned from a working card, so they ride along.  They
# are removed here so that the clone taken from this card afterwards is clean;
# on an end user's first boot this is (correctly) a no-op.
#
# Deliberately LAST: dropping the profiles takes the network down, and doing
# that first would cut off the SSH session used to run this by hand.
SC=/etc/NetworkManager/system-connections
if [ -d "$SC" ] && [ -n "$(ls -A "$SC" 2>/dev/null)" ]; then
	for p in "$SC"/*; do
		[ -e "$p" ] || continue
		rm -f "$p" && say "removed Wi-Fi profile $(basename "$p")"
		changed=1
	done
	# NM's runtime copies keep the SSID too (no PSK, but they are still our
	# network's fingerprints and they would be cloned as well).

	rm -f /var/lib/NetworkManager/seen-bssids /var/lib/NetworkManager/timestamps 2>/dev/null
	rm -f /var/lib/NetworkManager/*.lease 2>/dev/null
	say "Wi-Fi profiles removed -- this device is now offline until you rejoin a network"
fi

# --- one more secret: my own dev SSH key -----------------------------------
# /home/ark/.ssh/authorized_keys still held the ngpremote ed25519 key used for
# remote screen/keypress injection during bring-up.  Shipping that in a public
# image would leave a backdoor on every card flashed from it, so drop it -- but
# only when it really is that key, so anything the owner installs later stays.
AK=/home/ark/.ssh/authorized_keys
if [ -f "$AK" ] && grep -q ' ngpremote$' "$AK"; then
	rm -f "$AK" && say "removed leftover ngpremote public key from $AK"
	changed=1
fi

if [ "$changed" = 0 ] && [ -f "$HYG" ]; then
	say "already converged, nothing to do"
fi

# --- optional bring-up report ----------------------------------------------
# "firstboot.sh --diag" writes the same /boot/diag.txt used during bring-up;
# readable from a PC over the FAT partition without mounting the btrfs rootfs.
if [ "${1:-}" = "--diag" ]; then
	OUT=/boot/diag.txt
	{
		echo "===== generated: $(date) ====="
		uname -r; tr '\0' ' ' < /proc/device-tree/model; echo
		sha256sum /boot/Image /boot/rk3562-ngp45ht.dtb
		grep -aE '^(N:|P:)' /proc/bus/input/devices
		dmesg | grep -iE 'rk3562-joystick|mmcblk|LDO_REG8|regulator' | tail -30
		ls /dev/mmcblk* 2>&1
		amixer cget numid=37 2>/dev/null | tail -1
		cat /sys/kernel/debug/gpio 2>/dev/null | head -60
	} > "$OUT" 2>&1
	sync
fi
say "===== firstboot.sh done ====="
exit 0
