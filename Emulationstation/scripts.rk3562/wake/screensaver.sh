#!/bin/bash
# ES fires this on the input that ends its "sleep": the screensaver is over.
# After the black one (sleep/screensaver.sh) ES puts back a brightness of its
# own, kept from an earlier screensaver if at all, in the background; the one
# from the mark goes after it. The mark becomes "off <ms>": pause.sh then
# knows that a press of the power key a moment ago only woke the screen.
m=/run/darkos-screensaver
read -r s b _ < $m 2> /dev/null
[ "$s" = on ] || exit 0
echo "off $(date +%s%3N)" | sudo tee $m > /dev/null
( sleep 0.1
  for i in $(seq 1 20); do pgrep -x brightnessctl > /dev/null || break; sleep 0.05; done
  echo $b | sudo tee /sys/class/backlight/backlight/brightness ) > /dev/null 2>&1 &
