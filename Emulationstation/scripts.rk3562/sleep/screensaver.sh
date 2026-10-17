#!/bin/bash
# ES fires this when its screensaver has run its time ("sleep"). The "black"
# one only turns the backlight off: the device is awake, and a press of the
# power key is to light the screen, not to put the device to sleep. ES reads
# that key too and stops the screensaver itself, while ogage runs pause.sh at
# the same moment: which of the two comes first is chance. Hence the mark
# "on <brightness> <ES pid>" while the black screensaver runs, with the
# brightness from before it (udev keeps the last one other than 0 in
# /run/darkos-brightness, see finishing_touches-rk3562.sh); the wake script
# makes it "off <ms>". The other screensavers leave the backlight on, and the
# power key works as always. ES sets the backlight in the background, hence
# the wait.
( for i in $(seq 1 10); do
    if [ "$(cat /sys/class/backlight/backlight/brightness)" = 0 ]; then
      b=$(cat /run/darkos-brightness 2> /dev/null || cat /var/local/cur_bright.state 2> /dev/null)
      echo "on ${b:-60} $(pidof -s emulationstation)" | sudo tee /run/darkos-screensaver
      break
    fi
    sleep 0.1
  done ) > /dev/null 2>&1 &
