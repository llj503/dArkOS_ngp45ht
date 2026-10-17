#!/bin/bash
# NGP45HT: make SSH survive reboots.
#
# dArkOS's "Options -> Enable Remote Services" entry runs
# /opt/system/Enable Remote Services.sh, which only does
#   systemctl start ssh.service
# plus a commented-out `systemctl enable ssh`.  So SSH works for that one boot
# and is gone after the next power cycle, and the option has to be toggled by
# hand every single time.  This script does the missing `enable` (and starts
# the server now, so no reboot is needed), then verifies port 22 is actually
# listening.
#
# Idempotent -- safe to re-run.  Newly flashed cards get the same treatment
# automatically from /boot/firstboot.sh, so this is only needed on a card that
# is already in service.
#
# Usage:  sudo /usr/local/sbin/ngp-ssh-always-on.sh [--check]
set -u

port22() {
	if command -v ss >/dev/null 2>&1; then
		ss -ltn 2>/dev/null | grep -q '[:.]22[ ]'
		return
	fi
	awk 'NR>1 && $2 ~ /:0016$/ && $4 == "0A" { f = 1 } END { exit !f }' \
		/proc/net/tcp /proc/net/tcp6 2>/dev/null
}

if [ "${1:-}" = "--check" ]; then
	echo "ssh.service enabled : $(systemctl is-enabled ssh.service 2>&1)"
	echo "ssh.service active  : $(systemctl is-active ssh.service 2>&1)"
	if port22; then echo "port 22             : LISTENING"; else echo "port 22             : closed"; fi
	exit 0
fi

if [ "$(id -u)" != 0 ]; then
	echo "run as root (sudo $0)" >&2
	exit 1
fi

systemctl unmask ssh.service 2>/dev/null
systemctl enable ssh.service
mkdir -p /run/sshd
ssh-keygen -A >/dev/null 2>&1
systemctl is-active ssh.service >/dev/null 2>&1 || systemctl start ssh.service

i=0
while [ $i -lt 10 ] && ! port22; do i=$((i + 1)); sleep 1; done
if ! port22; then
	echo "systemd did not bring sshd up; starting /usr/sbin/sshd directly"
	/usr/sbin/sshd
	sleep 2
fi

echo
if port22; then
	echo "OK: SSH is listening on port 22 and will start automatically on boot."
else
	echo "FAILED: port 22 still closed.  systemctl status ssh.service:"
	systemctl status ssh.service --no-pager 2>&1 | head -20
	exit 1
fi

# Reminder, not a change: this device suspends itself after 30 idle minutes
# (/usr/local/bin/auto_suspend.py, timeout from /home/ark/.config/.TIMEOUT),
# and a suspended handheld obviously stops answering SSH.  Raise that file's
# value if you need a stubbornly reachable dev box.
echo "note: idle suspend is $(cat /home/ark/.config/.TIMEOUT 2>/dev/null || echo 30) min" \
     "(/home/ark/.config/.TIMEOUT) -- a suspended device will not answer SSH."
