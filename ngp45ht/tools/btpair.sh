#!/bin/bash
# Pair the Machenike G3V2 PRO over the onboard LE-only controller.
EXCLUDE="${EXCLUDE:-}"                # optional MAC of a nearby non-gamepad to skip
PATTERN="${1:-G3V2}"

timeout 6 bluetoothctl --timeout 3 scan off < /dev/null >/dev/null 2>&1
timeout 18 bluetoothctl --timeout 14 scan on < /dev/null 2>&1 > /tmp/scan.txt
echo "== seen this pass =="
grep -aoE "Device [0-9A-F:]{17}.*" /tmp/scan.txt | sort -u

ADDR=$(grep -aoE "Device [0-9A-F:]{17}.*" /tmp/scan.txt | grep -ai "$PATTERN" | tail -1 | awk '{print $2}')
if [ -z "$ADDR" ]; then
  echo "no name match for '$PATTERN'; falling back to first new non-excluded device"
  ADDR=$(grep -aoE "Device [0-9A-F:]{17}.*" /tmp/scan.txt | awk '{print $2}' \
         | grep -v -e "$EXCLUDE" -e "B4:65" | sort -u | tail -1)
fi
[ -z "$ADDR" ] && { echo "NOTHING TO PAIR"; exit 1; }
echo "== target $ADDR =="

echo "-- pair --"
timeout 34 bluetoothctl --timeout 28 pair $ADDR < /dev/null 2>&1 | tail -20
echo "-- trust --"
timeout 10 bluetoothctl --timeout 8 trust $ADDR < /dev/null 2>&1 | tail -3
echo "-- connect --"
timeout 40 bluetoothctl --timeout 34 connect $ADDR < /dev/null 2>&1 | tail -20
echo "-- info --"
timeout 10 bluetoothctl --timeout 6 info $ADDR < /dev/null 2>&1 | tail -20
echo "-- acl links --"
timeout 6 hcitool con 2>&1 | tail -4
echo "-- input nodes --"
grep -aE "^N: Name|^H: Handlers" /proc/bus/input/devices
echo "-- hidraw --"
ls /sys/class/hidraw/ 2>&1
echo "-- bond record --"
find /var/lib/bluetooth -type d -name "${ADDR//:/_}" -exec cat {}/info \; 2>&1 | head -24
