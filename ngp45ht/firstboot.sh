#!/bin/bash
# NGP45HT corrections the RG43H-based rootfs does not carry.
#
# Idempotent and safe to re-run: it converges the rootfs to what has been
# verified on hardware, so a reflash (which restores the stock rootfs) only
# needs this run once -- "sh /boot/firstboot.sh" or "systemctl start firstboot".
# The boot files themselves (Image + DTB) on the same FAT partition already
# contain the stick channel order, per-axis inversion and the RK817 LDO_REG8
# 3.3V always-on override, which is what makes the seven GPIO1/GPIO2 keys and
# the second TF slot work at all.
set -u
changed=0

# --- audio: PPSSPP was silent ---------------------------------------------
# ppsspp.sh routes the RK817 to the headphone output for .DEVICE = RG43H, but
# on this board the speaker is the codec's own SPK output (amp enable is the
# codec's spk-ctl on GPIO0_A7), so that route mutes the internal speaker.
f=/usr/local/bin/ppsspp.sh
if [ -f "$f" ] && grep -q "Playback Path' HP" "$f"; then
	[ -f "$f.ngpbak" ] || cp -a "$f" "$f.ngpbak"
	sed -i "s/Playback Path' HP/Playback Path' SPK/" "$f"
	echo "ppsspp.sh: Playback Path HP -> SPK"
	changed=1
fi

# --- audio: apply the route now, no reboot needed --------------------------
if command -v amixer >/dev/null 2>&1; then
	amixer -q sset 'Playback Path' SPK 2>/dev/null && :
fi

# --- input: L2/R2 are GPIO switches here ----------------------------------
# The base configs bind l2/r2 to the ABS_Z/ABS_RZ axes.  The kernel driver now
# drives those axes from the GPIO switches, but the digital buttons are what
# RetroArch wants on this pad, so bind the buttons and null the axes.
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
		echo "$(basename "$(dirname "$c")")/retroarch.cfg: l2/r2 -> btn 6/7, axes nulled"
		changed=1
	fi
done

# --- hygiene: the shipped base image carries real secrets -------------------
# Its /etc/ssh/ssh_host_*_key were generated once by the image build, so every
# card flashed from it shares the same host keys, and /etc/hostapd/hostapd.conf
# still holds the upstream author's AP passphrase.  Marker-guarded, so a later
# re-run of this script never rotates keys out from under an established
# known_hosts entry.
HYG=/etc/ngp45ht-hygiene.done
if [ ! -f "$HYG" ]; then
	if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
		rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub
		ssh-keygen -A >/dev/null 2>&1
		systemctl restart ssh 2>/dev/null || true
		echo "ssh host keys regenerated"
	fi
	h=/etc/hostapd/hostapd.conf
	if [ -f "$h" ] && grep -q "^ssid=ArkOS_AP_fbneo" "$h"; then
		sed -i -e 's/^ssid=.*/ssid=ArkOS_AP/' \
			-e 's/^wpa_passphrase=.*/wpa_passphrase=darkos0000/' "$h"
		echo "hostapd AP defaults neutralised"
	fi
	touch "$HYG"
fi

if [ "$changed" = 0 ] && [ -f "$HYG" ]; then
	echo "already converged, nothing to do"
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
exit 0
