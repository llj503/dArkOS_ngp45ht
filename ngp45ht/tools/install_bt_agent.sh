#!/bin/bash
# Install the pairing agent + pairing helper on the card and make them survive a
# reboot. Run as root (the fixes scripts already assume that path).
#
# Nothing here touches WiFi or the on-board keys; it only adds /usr/local/bin files,
# one unit, and AutoEnable in /etc/bluetooth/main.conf.
set -u
SRC=/home/ark/bt                 # devsh.py uploads land here as /home/ark/<name>
BIN=/usr/local/bin
fail=0

echo "== python bindings the agent needs =="
python3 -c 'import dbus, gi' 2>&1 | tail -1
if ! python3 -c 'import dbus, gi' 2>/dev/null; then
    echo "installing python3-gi (the agent uses the GLib main loop)"
    apt-get install -y python3-gi >/tmp/btgi.log 2>&1 || { echo "APT_FAIL"; tail -5 /tmp/btgi.log; fail=1; }
    python3 -c 'import dbus, gi' 2>&1 | tail -1
fi

echo "== install files =="
install -m 0755 -o root -g root "$SRC/ngp-bt-agent.py" $BIN/ngp-bt-agent.py || fail=1
install -m 0755 -o root -g root "$SRC/ngp-bt-pair.sh"  $BIN/ngp-bt-pair.sh  || fail=1
install -m 0644 -o root -g root "$SRC/ngp-bt-agent.service" /etc/systemd/system/ngp-bt-agent.service || fail=1

echo "== power the adapter by itself at boot =="
if grep -q '^AutoEnable=true' /etc/bluetooth/main.conf 2>/dev/null; then
    echo "already set"
else
    cp -a /etc/bluetooth/main.conf /root/main.conf.bak-$(date +%s) 2>/dev/null
    if grep -q '^\[General\]' /etc/bluetooth/main.conf; then
        sed -i '/^\[General\]/a AutoEnable=true' /etc/bluetooth/main.conf
    else
        printf '\n[General]\nAutoEnable=true\n' >> /etc/bluetooth/main.conf
    fi
    grep -n 'AutoEnable' /etc/bluetooth/main.conf | head -2
fi

systemctl daemon-reload
systemctl enable --now ngp-bt-agent.service 2>&1 | tail -2
sleep 2
echo "== state =="
systemctl is-active ngp-bt-agent bluetooth 2>&1 | tr '\n' ' '; echo
journalctl -u ngp-bt-agent --no-pager -n 5 2>&1 | tail -5

echo "== is the agent actually reachable? =="
# it owns no well-known name (the bus policy forbids that), so reach it by the unique
# connection name busctl reports for the unit -- this is the same object bluetoothd
# will call during a pairing attempt
UNIQ=$(busctl --system list 2>/dev/null | grep -a ngp-bt-agent | awk '{print $1}' | head -1)
echo "unique name: ${UNIQ:-NONE}"
if [ -n "$UNIQ" ]; then
    gdbus call --system --dest "$UNIQ" --object-path /org/bluez/agent/ngp45ht \
        --method org.bluez.Agent1.RequestConfirmation \
        /org/bluez/hci0/dev_00_11_22_33_44_55 123456 2>&1 | tail -2
    sleep 1
    echo "agent log should show the accepted request:"
    journalctl -u ngp-bt-agent --no-pager -n 6 2>&1 | grep -aE "registered|RequestConfirmation" | tail -3
fi
echo "INSTALL_BT_AGENT_DONE fail=$fail"
