#!/bin/bash
#
# Bluetooth toggle for RK3562 (RG52 Mini)
#
# On and off is whether the bluetooth unit is enabled: EmulationStation and
# Bluetooth.sh both read it that way ("enabled;" in systemctl status). So the
# switch enables or disables the units as well as starting or stopping them,
# and the choice holds after a reboot. Up to 1.0 it only started and stopped
# them; the unit stayed enabled, the menus said "On" whatever the radio did,
# and a reboot turned it back on.
#
# The units are the ones finishing_touches enables: bluez, bluealsa when it
# is there, and enable_bluetooth (powers the controller on at boot).
#

UNITS="bluetooth enable_bluetooth"
if systemctl cat bluealsa >/dev/null 2>&1; then
    UNITS="$UNITS bluealsa"
fi

if systemctl is-enabled --quiet bluetooth; then
    # Bluetooth is on, turn it off
    sudo systemctl disable --now $UNITS 2>/dev/null
    echo "Bluetooth disabled"
else
    # Bluetooth is off, turn it on
    sudo systemctl enable --now $UNITS 2>/dev/null
    echo "Bluetooth enabled"
fi
