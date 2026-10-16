#!/bin/bash
# Pair a Bluetooth gamepad (or headset) with the NGP45HT from SSH, no UI.
#
#   ngp-bt-pair.sh scan 20            what is in range right now
#   ngp-bt-pair.sh Pro 2              match a name, then pair + trust + connect
#   ngp-bt-pair.sh connect C0:..:...  reconnect a bonded device by address
#   ngp-bt-pair.sh list               what BlueZ remembers
#   ngp-bt-pair.sh forget C0:..:...   untrust + remove the bond
#
# Pairing only works because ngp-bt-agent.service answers the request; without it
# bluetoothctl fails the same way the reference project described ("found but
# disconnects instantly").  This board's controller has no BR/EDR, so the pad has to
# be in a BLE mode -- a classic-only pad will never even show up here.
set -u
BC="bluetoothctl"
HCI=/org/bluez/hci0

do_scan() {
    local secs=${1:-20}
    timeout $((secs + 5)) $BC --timeout $secs scan on 2>&1 | grep -aE '\[NEW\]|\[DEV\]' | tail -30
    echo "--- visible now ---"
    $BC devices
}

do_pair() {
    local want="$1"
    local found mac name
    timeout 30 $BC --timeout 25 scan on >/dev/null 2>&1
    found=$($BC devices | grep -ai "$want" | head -1)
    if [ -z "$found" ]; then
        echo "no device matching '$want' while scanning; run: $0 scan 30"
        exit 1
    fi
    mac=$(echo "$found" | awk '{print $2}')
    name=$(echo "$found" | cut -d' ' -f3-)
    echo "pairing $name [$mac]"
    # the pad must not be holding a bond with a phone at the same time
    $BC --timeout 20 pair $mac 2>&1 | tail -3
    $BC trust $mac >/dev/null 2>&1
    $BC --timeout 20 connect $mac 2>&1 | tail -2
    echo "--- state ---"
    $BC --timeout 8 info $mac 2>&1 | grep -aE "Paired|Trusted|Connected|Icon|BatteryPercentage"
    echo "--- input devices (a gamepad must appear here) ---"
    cat /proc/bus/input/devices | grep -aiE "^N: Name=" | sed 's/^N: //'
    echo "--- evdev nodes ---"
    python3 -c 'import evdev; [print(d, evdev.InputDevice("/dev/input/"+d).name) for d in [x.split("/")[-1] for x in evdev.list_devices()]]' 2>/dev/null \
        || ls /dev/input/
}

case ${1:-} in
    scan)   do_scan "${2:-20}";;
    list)   $BC paired-devices; ls /var/lib/bluetooth/$HCI/ 2>/dev/null;;
    connect) mac="$2"; $BC --timeout 20 connect $mac 2>&1 | tail -2; $BC --timeout 8 info $mac 2>&1 | grep -aE "Paired|Trusted|Connected"; cat /proc/bus/input/devices | grep -aiE "^N: Name=";;
    forget) mac="$2"; $BC untrust $mac >/dev/null 2>&1; $BC --timeout 10 remove-device $mac >/dev/null 2>&1; rm -rf "/var/lib/bluetooth/$HCI/$mac"; echo removed $mac;;
    "")     sed -n '3,14p' "$0"; exit 1;;
    *)      do_pair "$1";;
esac
