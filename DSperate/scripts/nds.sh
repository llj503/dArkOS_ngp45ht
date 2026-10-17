#!/bin/bash

directory="$(dirname "$2" | cut -d "/" -f2)"

if [[ "$1" == "advanced_drastic" ]]; then
  for d in backup cheats savestates slot2; do
    if [[ ! -d "/${directory}/nds/$d" ]]; then
      mkdir /${directory}/nds/${d}
    fi
    if [[ -d "/opt/advanced_drastic/$d" && ! -L "/opt/advanced_drastic/$d" ]]; then
      cp -n /opt/advanced_drastic/${d}/* /${directory}/nds/${d}/
      rm -rf /opt/advanced_drastic/${d}/
    fi
    ln -sf /${directory}/nds/${d} /opt/advanced_drastic/
  done

  export LD_LIBRARY_PATH=/opt/advanced_drastic/libs:$LD_LIBRARY_PATH
  cd /opt/advanced_drastic
  unset LD_PRELOAD
  export LD_PRELOAD=/opt/advanced_drastic/libs/libadvdrastic.so

  echo "VAR=drastic" > /home/ark/.config/KILLIT
  sudo systemctl restart killer_daemon.service

  ./drastic "$2"

  sudo systemctl stop killer_daemon.service

  sudo systemctl restart ogage &
elif [[ "$1" == "drastic" ]]; then
  for d in backup cheats savestates slot2; do
    if [[ ! -d "/${directory}/nds/$d" ]]; then
      mkdir /${directory}/nds/${d}
    fi
    if [[ -d "/opt/drastic/$d" && ! -L "/opt/drastic/$d" ]]; then
      cp -n /opt/drastic/${d}/* /${directory}/nds/${d}/
      rm -rf /opt/drastic/${d}/
    fi
    ln -sf /${directory}/nds/${d} /opt/drastic/
  done

  echo "VAR=drastic" > /home/ark/.config/KILLIT
  sudo systemctl restart killer_daemon.service

  cd /opt/drastic
  ./drastic "$2"

  sudo systemctl stop killer_daemon.service

  sudo systemctl restart ogage &
elif [[ "$1" == "dsperate" ]]; then
  if [[ -e "/dev/input/by-path/platform-ff300000.usb-usb-0:1.2:1.0-event-joystick" ]]; then
    sdl_controllerconfig="03000000091200000031000011010000,OpenSimHardware OSH PB Controller,a:b1,b:b0,x:b3,y:b2,leftshoulder:b4,rightshoulder:b5,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,leftx:a0~,lefty:a1~,leftstick:b8,lefttrigger:b10,rightstick:b9,back:b7,start:b6,rightx:a2,righty:a3,righttrigger:b11,platform:Linux,"
  elif [[ -e "/dev/input/by-path/platform-odroidgo2-joypad-event-joystick" ]]; then
    if [[ ! -z $(cat /etc/emulationstation/es_input.cfg | grep "190000004b4800000010000001010000") ]]; then
      sdl_controllerconfig="190000004b4800000010000001010000,GO-Advance Gamepad (rev 1.1),a:b0,b:b1,x:b3,y:b2,leftshoulder:b4,rightshoulder:b5,dpdown:b9,dpleft:b10,dpright:b11,dpup:b8,leftx:a0,lefty:a1,back:b12,leftstick:b13,lefttrigger:b14,rightstick:b16,righttrigger:b15,start:b17,platform:Linux,"
    else
      sdl_controllerconfig="190000004b4800000010000000010000,GO-Advance Gamepad,a:b1,b:b0,x:b2,y:b3,leftshoulder:b4,rightshoulder:b5,dpdown:b7,dpleft:b8,dpright:b9,dpup:b6,leftx:a0,lefty:a1,back:b10,lefttrigger:b12,righttrigger:b13,start:b15,platform:Linux,"
    fi
  elif [[ -e "/dev/input/by-path/platform-odroidgo3-joypad-event-joystick" ]]; then
    sdl_controllerconfig="190000004b4800000011000000010000,GO-Super Gamepad,x:b3,a:b0,b:b1,y:b2,back:b12,start:b13,dpleft:b10,dpdown:b9,dpright:b11,dpup:b8,leftshoulder:b4,lefttrigger:b6,rightshoulder:b5,righttrigger:b7,leftstick:b14,rightstick:b15,guide:b16,leftx:a0,lefty:a1,rightx:a2,righty:a3,platform:Linux,"
  elif [[ -e "/dev/input/by-path/platform-singleadc-joypad-event-joystick" ]]; then
    sdl_controllerconfig="190000004b4800000111000000010000,retrogame_joypad,a:b0,b:b1,x:b3,y:b2,back:b8,start:b9,rightstick:b12,leftstick:b11,dpleft:b15,dpdown:b14,dpright:b16,dpup:b13,leftshoulder:b4,lefttrigger:b6,rightshoulder:b5,righttrigger:b7,guide:b10,leftx:a0,lefty:a1,rightx:a2,righty:a3,platform:Linux,"
  elif [[ -e "/dev/input/by-path/platform-play_joystick-event-joystick" ]]; then
    # RG52 Mini (rk3562-joystick), as in ppsspp/gamecontrollerdb.txt.rg52mini
    sdl_controllerconfig="1900a4dd726b333536322d6a6f797300,rk3562-joystick,a:b1,b:b0,x:b2,y:b3,leftshoulder:b4,rightshoulder:b5,back:b8,start:b9,guide:b10,leftstick:b11,rightstick:b12,dpup:b13,dpdown:b14,dpleft:b15,dpright:b16,lefttrigger:a2,righttrigger:a5,leftx:a0,lefty:a1,rightx:a3,righty:a4,platform:Linux,"
  else
    sdl_controllerconfig="19000000030000000300000002030000,gameforce_gamepad,leftstick:b14,rightx:a3,leftshoulder:b4,start:b9,lefty:a0,dpup:b10,righty:a2,a:b1,b:b0,guide:b16,dpdown:b11,rightshoulder:b5,righttrigger:b7,rightstick:b15,dpright:b13,x:b2,back:b8,leftx:a1,y:b3,dpleft:b12,lefttrigger:b6,platform:Linux,"
  fi
  # The DSperate standalone emulator does not support 7z archive files.  We'll take care of that here
  game="$2"
  ext="${2##*.}"
  if [[ "${ext,,}" == "7z" ]]; then
    if [ ! -d "/dev/shm/ndsroms" ]; then
      mkdir -p /dev/shm/ndsroms
    else
      rm -rf /dev/shm/ndsroms/*
    fi
    # game variable will be updated with the file that is found in the 7z archive
    ROM="$game"
    7z e "$ROM" -bd -aoa -o/dev/shm/ndsroms/

    if [ $? != 0 ]; then
      printf "\nCouldn't decompress $ROM\nSomething seems to be wrong with this archive." > /dev/tty1
      sleep 5
      printf "\033c" > /dev/tty1
      exit 1
    fi

    for CART in nds NDS; do
      game=`find /dev/shm/ndsroms/ -iname "*.${CART}" | tac | head -n 1`
      if [ ! -z "$game" ]; then
        break;
      fi
    done
    if [ -z "$game" ]; then
      printf "\nCouldn't find a compatible rom of type .nds or .NDS in $ROM\n" > /dev/tty1
      sleep 5
      printf "\033c" > /dev/tty1
      exit 1
    fi
  fi

  if [[ ! -d "/${directory}/nds/dsperate" ]]; then
    mkdir /${directory}/nds/dsperate
    cp /opt/DSperate/config/dsperate.ini /${directory}/nds/dsperate/.
  fi

  if [[ ! -s "/${directory}/nds/dsperate/dsperate.ini" ]]; then
    cp /opt/DSperate/config/dsperate.ini /${directory}/nds/dsperate/.
  fi

  ln -sfn /${directory}/nds/dsperate /home/ark/.config/

  if [[ ! -d "/${directory}/nds/cheats" ]]; then
    mkdir /${directory}/nds/cheats
  fi

  if [[ ! -d "/${directory}/nds/savestates" ]]; then
    mkdir /${directory}/nds/savestates
  fi

  sed -i "/saves =/c\saves = /${directory}/nds" /${directory}/nds/dsperate/dsperate.ini
  sed -i "/states =/c\states = /${directory}/nds/savestates" /${directory}/nds/dsperate/dsperate.ini
  sed -i "/cheats =/c\cheats = /${directory}/nds/cheats" /${directory}/nds/dsperate/dsperate.ini

  SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig" /opt/DSperate/dsperate "$game" --bios9 /${directory}/bios/nds_bios9.bin --bios7 /${directory}/bios/nds_bios7.bin --firmware /${directory}/bios/nds_firmware.bin

  if [ -d "/dev/shm/ndsroms" ]; then
    rm -rf /dev/shm/ndsroms
  fi
fi
