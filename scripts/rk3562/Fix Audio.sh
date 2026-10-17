#!/bin/bash
#
# Fix Audio for RK3562 (RG52 Mini)
# Resets audio configuration for RK817 codec
#

# Kill any audio-using processes
sudo killall -9 retroarch 2>/dev/null
sudo killall -9 emulationstation 2>/dev/null

# Restore default audio config
cp /home/ark/.asoundrcbak /home/ark/.asoundrc

# Restore ALSA state
sudo /usr/sbin/alsactl restore -f /var/local/asound.state 2>/dev/null

# Set playback path to speaker. On the RG52 Mini that is SPK: the codec drives
# the speaker amplifier (spk-ctl-gpios) only on that path, and HP silences the
# speaker. The RG56Pro and RG43H run their speaker from the HP output, as
# spktoggle.sh has it.
if [ "$(cat /home/ark/.config/.DEVICE 2>/dev/null)" == "RG52MINI" ]; then
  amixer -q sset 'Playback Path' SPK 2>/dev/null
else
  amixer -q sset 'Playback Path' HP 2>/dev/null
fi

echo "Audio configuration reset for RK817 codec"
sleep 2
