#!/bin/bash
# Bind the two e0 interfaces of the onboard AIC8800DC from built-in btusb to the
# vendor aic_btusb (BlueZ mode, BLUEDROID=0) and watch how far the patch download
# gets. Nothing here persists: a reboot restores btusb + working WiFi.

log() { echo "### $*"; }

log "firmware dir actually on this card"
ls -l /lib/firmware/aic8800DC/ | grep -aE "fw_patch|fw_adid|fmacfwbt" || echo "(no patch files!)"

log "before: who owns the interfaces"
ls /sys/bus/usb/drivers/btusb/ 2>&1 | tr '\n' ' '; echo
btmgmt info 2>&1 | sed -n '/supported settings/,/current settings/p'

log "unbind btusb interfaces"
for i in 1-1:1.0 1-1:1.1; do
  if [ -e "/sys/bus/usb/drivers/btusb/$i" ]; then echo "$i" > /sys/bus/usb/drivers/btusb/unbind && log "unbound $i"; else log "$i was not bound"; fi
done
sleep 1

log "insmod"
dmesg > /tmp/dmesg.before 2>&1
if /sbin/insmod /home/ark/aic_btusb.ko 2>/tmp/insmod.err; then
  log "insmod ok, waiting 8s for the download sequence"
  sleep 8
else
  log "insmod FAILED: $(cat /tmp/insmod.err)"; dmesg | tail -8
fi

log "dmesg since insmod"
dmesg > /tmp/dmesg.after 2>&1
diff /tmp/dmesg.before /tmp/dmesg.after 2>/dev/null | grep -a "^>" | sed "s/^> //" \
  | grep -aiE "chip_id|sub_chip|fw status|download|patch|firmware path|fail|hci|btusb|adid|ble|error" | head -40

log "adapter state"
btmgmt info 2>&1 | sed -n '1,24p'
hciconfig -a 2>&1 | head -14
ls /sys/class/bluetooth/ 2>&1

log "rollback"
/sbin/rmmod aic_btusb 2>&1 && log "aic_btusb removed"
for i in 1-1:1.0 1-1:1.1; do
  [ ! -e "/sys/bus/usb/drivers/btusb/$i" ] && echo "$i" > /sys/bus/usb/drivers/btusb/bind 2>/dev/null
done
sleep 3
log "after rollback"
ls /sys/bus/usb/drivers/btusb/ 2>&1 | tr '\n' ' '; echo
btmgmt info 2>&1 | sed -n '/current settings/,+1p'
dmesg | tail -6
echo "PING:"; ping -c 2 -W 2 192.168.0.1 2>&1 | tail -2
