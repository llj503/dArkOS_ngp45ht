#!/bin/bash

# create a temporary named pipe to communicate with bluealsactl monitor
FIFO_PATH=$(mktemp -u)
mkfifo $FIFO_PATH
# attach it to unused file descriptor FIFO_FD
exec {FIFO_FD}<>$FIFO_PATH
# unlink the named pipe
rm $FIFO_PATH

# make sure the pipeline is shut down if this script interrupted
trap "kill %1; exec {FIFO_FD}>&-; ln -sf /dev/null ~/.asoundrc-default; exit 0" INT TERM

# start bluealsactl monitor in background
bluealsactl --quiet monitor >&$FIFO_FD &

if [ -f "/usr/local/bin/Kodi.sh" ]; then
  if [ ! -f "/home/ark/.kodi/userdata/advancedsettings.xml.bak" ]; then
    cp -f /home/ark/.kodi/userdata/advancedsettings.xml /home/ark/.kodi/userdata/advancedsettings.xml.bak
  fi
fi

until false; do
	if [[ $(bluealsactl --quiet list-pcms | grep -Ec '/a2dp(src|sink)/sink$') -gt 0 ]] ; then
		if test -z "$(lsmod | grep snd_aloop | tr -d '\0')"
		then
		  sudo modprobe snd-aloop
		fi
		syncdevice=$(bluealsactl --quiet list-pcms | grep -o -E '([[:xdigit:]]{2}_){5}[[:xdigit:]]{2}' | sed '/_/s//:/g')
		alsaloop -C hw:Loopback,1,0 -P bluealsa:DEV=${syncdevice},PROFILE=a2dp --sync=none -c 2 -r 48000 -f s16_le -t 100000 &
		cp -f /home/ark/.asoundrcbt /home/ark/.asoundrc
		if [[ -z $(pgrep -x finish.sh) ]] && [[ -z $(pgrep -x pause.sh) ]]; then
		  sudo systemctl restart ogage
		fi
		if [ -f "/usr/local/bin/Kodi.sh" ]; then
		  if test -z "$(cat /home/ark/.kodi/userdata/advancedsettings.xml | grep "<audiooutput>" | tr -d '\0')"
		  then
		    sed -i '/<advancedsettings>/s//<advancedsettings>\n        <audiooutput>\n                <audiodevice>ALSA:default<\/audiodevice>\n        <\/audiooutput>/' /home/ark/.kodi/userdata/advancedsettings.xml
		  elif test -z "$(cat /home/ark/.kodi/userdata/advancedsettings.xml | grep "<audiodevice>" | tr -d '\0')"
		  then
		    sed -i '/<audiooutput>/s//<audiooutput>\n                <audiodevice>ALSA:default<\/audiodevice>/' /home/ark/.kodi/userdata/advancedsettings.xml
		  else
		    sed -i '/<audiodevice>/c\                <audiodevice>ALSA:default<\/audiodevice>' /home/ark/.kodi/userdata/advancedsettings.xml
		  fi
		fi
	else
		pkill alsaloop
		cp -f /home/ark/.asoundrcbak /home/ark/.asoundrc
		if [[ -z $(pgrep -x finish.sh) ]] && [[ -z $(pgrep -x pause.sh) ]]; then
		  sudo systemctl restart ogage
		fi
		if [ -f "/usr/local/bin/Kodi.sh" ]; then
		  sed -i '/<audiodevice>/c\                <audiodevice><\/audiodevice>' /home/ark/.kodi/userdata/advancedsettings.xml
		fi
	fi
	read
done <&$FIFO_FD


