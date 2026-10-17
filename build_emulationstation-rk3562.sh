#!/bin/bash
#
# Build and install EmulationStation-fcamod for RK3562 (RG52 Mini)
#

if [ -f exports.sh ];
then
  source exports.sh
fi
echo "export devid=$(printenv DEV_ID)" | sudo tee Arkbuild/home/ark/ES_VARIABLES.txt
echo "export devpass=$(printenv DEV_PASS)" | sudo tee -a Arkbuild/home/ark/ES_VARIABLES.txt
echo "export apikey=$(printenv TGDB_APIKEY)" | sudo tee -a Arkbuild/home/ark/ES_VARIABLES.txt
echo "export softname=\"dArkOS-${UNIT}\"" | sudo tee -a Arkbuild/home/ark/ES_VARIABLES.txt

# ES lists the emulator governors from a fixed list in SystemData.h. RG52 Mini
# adds "overclock" after performance (scripts/perfoc, run by perfmax); the
# "_oc" in the cache key keeps a cached ES without it out.
ES_GOV_OLD='{"performance", "ondemand", "powersave"}'
ES_GOV_NEW='{"performance", "overclock", "ondemand", "powersave"}'
if [ -f "Arkbuild_package_cache/${CHIPSET}/emulationstation.tar.gz" ] && [ "$(cat Arkbuild_package_cache/${CHIPSET}/emulationstation.commit)" == "$(curl -s https://api.github.com/repos/christianhaitian/EmulationStation-fcamod/commits/503noTTS | jq -r '.sha')_oc" ]; then
    sudo tar -xvzpf Arkbuild_package_cache/${CHIPSET}/emulationstation.tar.gz
    sudo rm Arkbuild/home/ark/ES_VARIABLES.txt
else
    call_chroot "apt-get -y update && eatmydata apt-get -y install libfreeimage3 fonts-droid-fallback libfreetype6 curl vlc-bin libsdl2-mixer-2.0-0"
    call_chroot "cd /home/ark &&
      source ES_VARIABLES.txt &&
      rm ES_VARIABLES.txt &&
      git clone --recursive --depth=1 https://github.com/christianhaitian/EmulationStation-fcamod -b 503noTTS &&
      cd EmulationStation-fcamod &&
      git submodule update --init &&
      grep -qF '${ES_GOV_OLD}' es-app/src/SystemData.h &&
      sed -i 's/${ES_GOV_OLD}/${ES_GOV_NEW}/' es-app/src/SystemData.h &&
      grep -qF '${ES_GOV_NEW}' es-app/src/SystemData.h &&
      cmake -DSCREENSCRAPER_DEV_LOGIN=\"devid=\$devid&devpassword=\$devpass\" -DGAMESDB_APIKEY=\"\$apikey\" -DSCREENSCRAPER_SOFTNAME=\"\$softname\" . &&
      make -j\$(nproc) &&
      mkdir -pv /usr/bin/emulationstation &&
      cp -a emulationstation /usr/bin/emulationstation &&
      chmod 777 /usr/bin/emulationstation &&
      cp -a resources /usr/bin/emulationstation/
      "
    if [ -f "Arkbuild_package_cache/${CHIPSET}/emulationstation.tar.gz" ]; then
      sudo rm -f Arkbuild_package_cache/${CHIPSET}/emulationstation.tar.gz
    fi
    if [ -f "Arkbuild_package_cache/${CHIPSET}/emulationstation.commit" ]; then
      sudo rm -f Arkbuild_package_cache/${CHIPSET}/emulationstation.commit
    fi
    sudo tar -czpf Arkbuild_package_cache/${CHIPSET}/emulationstation.tar.gz Arkbuild/usr/bin/emulationstation/
    sudo git --git-dir=Arkbuild/home/ark/EmulationStation-fcamod/.git --work-tree=Arkbuild/home/ark/EmulationStation-fcamod rev-parse HEAD | sed 's/$/_oc/' | sudo tee Arkbuild_package_cache/${CHIPSET}/emulationstation.commit > /dev/null
fi

# RK3562: ES runs on the system Mali (g29p1) like every other app. No DT_RPATH
# override is needed anymore — g29p1's GLES 1.0 works, so the old g13p0-for-ES
# split (and the leak it caused into spawned emulators) is gone.

sudo rm -rf Arkbuild/home/ark/EmulationStation-fcamod
sudo mkdir -p Arkbuild/etc/emulationstation/themes

# Use rk3566 configs as base (similar hardware capabilities)
if [[ "${BUILD_ARMHF}" == "y" ]]; then
  if [ -f "Emulationstation/es_systems.cfg.${CHIPSET}" ]; then
    sudo cp Emulationstation/es_systems.cfg.${CHIPSET} Arkbuild/etc/emulationstation/es_systems.cfg
  else
    sudo cp Emulationstation/es_systems.cfg.rk3566 Arkbuild/etc/emulationstation/es_systems.cfg
  fi
else
  if [ -f "Emulationstation/es_systems.cfg.${CHIPSET}-64bit_Only" ]; then
    sudo cp Emulationstation/es_systems.cfg.${CHIPSET}-64bit_Only Arkbuild/etc/emulationstation/es_systems.cfg
  else
    sudo cp Emulationstation/es_systems.cfg.rk3566-64bit_Only Arkbuild/etc/emulationstation/es_systems.cfg
  fi
fi

# Use existing config or fall back to rk3566/353m configs
if [ -f "Emulationstation/es_input.cfg.${UNIT}" ]; then
  sudo cp Emulationstation/es_input.cfg.${UNIT} Arkbuild/etc/emulationstation/es_input.cfg
else
  sudo cp Emulationstation/es_input.cfg.353m Arkbuild/etc/emulationstation/es_input.cfg
fi

# Ship a PortMaster-specific es_input to ~/.config/emulationstation/ so that
# PortMaster's control.txt runs mapper.py on it.  The kernel now emits
# compass-correct codes (A=East=BTN_EAST/305=SDL2 b1, B=South=BTN_SOUTH/304=b0),
# so bare SDL2 auto-map gives SDL-A=South -- i.e. pressing physical A (East) would
# act as SDL-B in ports (the "A acts as B" symptom).  mapper.py hardcodes an
# a<->b / x<->y swap, so we feed it the INVERSE (Xbox-positional: a=South, b=East,
# x=West, y=North) and it emits a:b1,b:b0,x:b2,y:b3 = East=SDL-A, matching every
# other emulator.  NOTE: this is a DIFFERENT file from the Nintendo-labelled
# /etc/emulationstation/es_input.cfg used for ES menu nav; shipping THAT here would
# make mapper.py emit South=SDL-A.  ES does not read ~/.config/emulationstation/,
# so this only affects PortMaster.  See es_input.cfg.portmaster.rk3562 for details.
if [ -f "Emulationstation/es_input.cfg.portmaster.${CHIPSET}" ]; then
  # mapper.py parses this with python xml.etree; it MUST be well-formed XML or it
  # crashes, the pad is left unmapped, and ports fall back to auto-map (A/B reversed).
  # A stray double-hyphen inside the XML comment is enough to break it -- guard here
  # so a malformed es_input fails the build loudly instead of shipping silently broken.
  python3 -c "import xml.etree.ElementTree as ET; ET.parse('Emulationstation/es_input.cfg.portmaster.${CHIPSET}')"
  verify_action
  sudo mkdir -p Arkbuild/home/ark/.config/emulationstation
  sudo cp Emulationstation/es_input.cfg.portmaster.${CHIPSET} \
    Arkbuild/home/ark/.config/emulationstation/es_input.cfg
  call_chroot "chown -R ark:ark /home/ark/.config/emulationstation"
fi

if [ -f "Emulationstation/es_settings.cfg.${UNIT}" ]; then
  sudo cp Emulationstation/es_settings.cfg.${UNIT} Arkbuild/home/ark/.emulationstation/es_settings.cfg
else
  sudo cp Emulationstation/es_settings.cfg.353m Arkbuild/home/ark/.emulationstation/es_settings.cfg
fi

if [ -f "Emulationstation/emulationstation.sh.${UNIT}" ]; then
  sudo cp Emulationstation/emulationstation.sh.${UNIT} Arkbuild/usr/bin/emulationstation/emulationstation.sh
else
  sudo cp Emulationstation/emulationstation.sh.353m Arkbuild/usr/bin/emulationstation/emulationstation.sh
fi

sudo cp Emulationstation/fonts/* Arkbuild/usr/bin/emulationstation/resources/
sudo mkdir -p Arkbuild/usr/share/fonts/truetype/droid/
sudo wget -t 5 -T 30 --no-check-certificate https://github.com/aosp-mirror/platform_frameworks_base/raw/refs/heads/main/data/fonts/DroidSansFallbackFull.ttf -O Arkbuild/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf
sudo cp -R Emulationstation/scripts/ Arkbuild/home/ark/.emulationstation/
sudo cp -R Emulationstation/scripts.rk3562/. Arkbuild/home/ark/.emulationstation/scripts/
sudo chmod -R 777 Arkbuild/home/ark/.emulationstation/scripts/*
call_chroot "chown -R ark:ark /etc/emulationstation/"
call_chroot "chown -R ark:ark /home/ark/"
sudo chmod 777 Arkbuild/usr/bin/emulationstation/emulationstation.sh
sudo cp Emulationstation/emulationstation.service Arkbuild/etc/systemd/system/emulationstation.service
call_chroot "systemctl enable emulationstation"
