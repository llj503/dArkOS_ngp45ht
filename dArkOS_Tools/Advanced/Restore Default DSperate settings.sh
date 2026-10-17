#!/bin/bash

. /usr/local/bin/buttonmon.sh

if compgen -G "/boot/rk3566*" > /dev/null; then
  if test ! -z "$(cat /home/ark/.config/.DEVICE | grep RGB20PRO | tr -d '\0')"
  then
    sudo setfont /usr/share/consolefonts/Lat7-TerminusBold32x16.psf.gz
  else
    sudo setfont /usr/share/consolefonts/Lat7-TerminusBold28x14.psf.gz
  fi
  height="20"
  width="60"
fi

if test ! -z "$(cat /etc/fstab | grep roms2 | tr -d '\0')"
then
  directory="roms2"
else
  directory="roms"
fi

printf "\nAre you sure you want to restore the joystick functionality for DSperate standalone?\n"
printf "\nPress A to continue.  Press B to exit.\n"
while true
do
    Test_Button_A
    if [ "$?" -eq "10" ]; then
      cp -f /opt/DSperate/config/dsperate.ini /${directory}/nds/dsperate/.
      if [ $? == 0 ]; then
        printf "\nRestored the DSperate standalone emulator joystick functionality."
        sleep 5
      else
        printf "\nFailed to restore the DSperate standalone emulator joystick functionality."
        sleep 5
      fi
      exit 0
	fi

    Test_Button_B
    if [ "$?" -eq "10" ]; then
	  printf "\nExiting without restoring the DSperate standalone emulator joystick functionality."
	  sleep 1
      exit 0
	fi
done
