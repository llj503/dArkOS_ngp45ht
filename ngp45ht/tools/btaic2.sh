#!/bin/bash
# After the forced patch download, power-cycle the adapter so the host re-reads
# local features/version info, then look for bredr. Reversible: reboot restores
# built-in btusb.
KO=${1:-/home/ark/aic_btusb_force.ko}
log() { echo "### $*"; }

for i in 1-1:1.0 1-1:1.1; do
  [ -e "/sys/bus/usb/drivers/btusb/$i" ] && echo "$i" > /sys/bus/usb/drivers/btusb/unbind && log "unbound $i"
done
sleep 1
dmesg > /tmp/dmesg.before 2>&1
/sbin/insmod $KO 2>/tmp/insmod.err || { log "insmod failed: $(cat /tmp/insmod.err)"; exit 1; }
log "insmod ok, giving the patch 12s to finish"
sleep 12

log "new dmesg, tail (what happened after the upload)"
dmesg > /tmp/dmesg.after 2>&1
diff /tmp/dmesg.before /tmp/dmesg.after 2>/dev/null | grep -a "^>" | sed "s/^> //" | tail -30

log "power cycle the adapter so features get re-read"
btmgmt power off 2>&1 | tail -2; sleep 2
btmgmt power on  2>&1 | tail -2; sleep 3

log "capabilities now"
btmgmt info 2>&1 | sed -n '1,22p'
hciconfig -a 2>&1 | head -16
echo "-- read local name --"; hcitool -i hci0 cmd 0x03 0x0014 2>&1 | head -3
echo "-- read buffered size / features probe --"; hcitool -i hci0 cmd 0x03 0x0003 2>&1 | head -3

log "can a connection be opened at all?"
if [ -n "${TARGET:-}" ]; then timeout 8 hcitool -i hci0 lecc "$TARGET" 2>&1 | head -3
else log "no TARGET MAC given, skipping the connect attempt"; fi
timeout 6 hcitool con 2>&1 | tail -3

log "rollback"
/sbin/rmmod aic_btusb 2>&1 && log removed
for i in 1-1:1.0 1-1:1.1; do
  [ ! -e "/sys/bus/usb/drivers/btusb/$i" ] && echo "$i" > /sys/bus/usb/drivers/btusb/bind 2>/dev/null
done
sleep 3; btmgmt power on 2>&1 | tail -1
echo "PING:"; ping -c 2 -W 2 192.168.0.1 2>&1 | tail -2
