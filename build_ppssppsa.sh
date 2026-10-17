#!/bin/bash

# Build and install PPSSPP standalone emulator
# For rk3562, the core_builds repo is a local submodule (bmdhacks fork)
if [ "$CHIPSET" == "rk3562" ]; then
  PPSSPP_TAG=$(grep -oP '(?<=TAG=").*?(?=")' rk3562_core_builds/scripts/ppsspp.sh)
else
  PPSSPP_TAG=$(curl -s https://raw.githubusercontent.com/christianhaitian/${CORE_BUILDS_CHIPSET}_core_builds/refs/heads/master/scripts/ppsspp.sh | grep -oP '(?<=TAG=").*?(?=")')
fi
# Same reasoning as build_fake08.sh: the upstream tag does not move when we
# change compiler flags in the recipe, and this one carries the
# -fno-stack-protector work.
PPSSPP_RECIPE_SHA=$(sha1sum ${CHIPSET}_core_builds/scripts/ppsspp.sh 2>/dev/null | cut -c1-12)
if [ -f "Arkbuild_package_cache/${CHIPSET}/ppsspp_${UNIT}.tar.gz" ] && [ "$(cat Arkbuild_package_cache/${CHIPSET}/ppsspp_${UNIT}.commit)" == "${PPSSPP_TAG}-${PPSSPP_RECIPE_SHA}" ]; then
    sudo tar -xvzpf Arkbuild_package_cache/${CHIPSET}/ppsspp_${UNIT}.tar.gz
else
	if [ "$CHIPSET" == "rk3562" ]; then
	  # Remove libvulkan-dev dependency to avoid pulling in Mesa's loader
	  # (we use Rockchip's proprietary Vulkan loader; PPSSPP bundles its own headers)
	  sed -i 's/ libvulkan-dev//' Arkbuild/home/ark/${CHIPSET}_core_builds/scripts/ppsspp.sh
	  # Skip patch-003 (320x240 hardcode) — that's for small-screen RK3326 devices.
	  # RK3562 uses VK_KHR_display which needs pixel_xres/yres to match the actual
	  # display mode; SDL reports 1280x720 via RGA rotation, not 320x240.
	  rm -f Arkbuild/home/ark/${CHIPSET}_core_builds/patches/ppsspp-patch-003-fix-window-size.patch
	  # The Vulkan rotation patch is only for portrait-panel devices (e.g. RG52 Mini).
	  # Remove it for landscape-native devices to avoid unnecessary rotation.
	  if [ "$UNIT" != "rg52mini" ]; then
	    rm -f Arkbuild/home/ark/${CHIPSET}_core_builds/patches/ppsspp-patch-010-rk3562-vulkan-rotation.patch
	  fi
	fi
	# PPSSPP is the only emulator we build from source that still picks up
	# Debian gcc's default -fstack-protector-strong and _FORTIFY_SOURCE=2:
	# RetroArch, Flycast, ScummVM, PCSX2 and Mednafen all come out without
	# them because their own build systems set the flags. Those checks land
	# in the JIT and GPU hot paths, and this is an offline handheld that only
	# runs ROMs its owner put there, so drop them here too.
	# The flags live in rk3562_core_builds/scripts/ppsspp.sh, on the two
	# -DCMAKE_{C,CXX}_FLAGS arguments. Exporting CFLAGS/CXXFLAGS here does
	# nothing: cmake only falls back to the environment when those cache
	# variables are unset, and that script sets both. This was exactly that
	# mistake until 2026-09-16, when the generated flags.make showed
	# -mtune=cortex-a53 present and -fno-stack-protector absent.
	call_chroot "cd /home/ark &&
	  cd ${CHIPSET}_core_builds &&
	  chmod 777 builds-alt.sh &&
	  eatmydata ./builds-alt.sh ppsspp
	  "
	sudo mkdir -p Arkbuild/opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM
	sudo cp -Ra Arkbuild/home/ark/${CHIPSET}_core_builds/ppsspp/build/assets/ Arkbuild/opt/ppsspp/
	sudo cp -a Arkbuild/home/ark/${CHIPSET}_core_builds/ppsspp/LICENSE.TXT Arkbuild/opt/ppsspp/
	sudo cp -a Arkbuild/home/ark/${CHIPSET}_core_builds/ppsspp/build/PPSSPPSDL Arkbuild/opt/ppsspp/
	if [ -f "Arkbuild_package_cache/${CHIPSET}/ppsspp_${UNIT}.tar.gz" ]; then
	  sudo rm -f Arkbuild_package_cache/${CHIPSET}/ppsspp_${UNIT}.tar.gz
	fi
	if [ -f "Arkbuild_package_cache/${CHIPSET}/ppsspp_${UNIT}.commit" ]; then
	  sudo rm -f Arkbuild_package_cache/${CHIPSET}/ppsspp_${UNIT}.commit
	fi
	sudo tar -czpf Arkbuild_package_cache/${CHIPSET}/ppsspp_${UNIT}.tar.gz Arkbuild/opt/ppsspp/
	echo "${PPSSPP_TAG}-${PPSSPP_RECIPE_SHA}" > Arkbuild_package_cache/${CHIPSET}/ppsspp_${UNIT}.commit
fi
sudo cp ppsspp/gamecontrollerdb.txt.${UNIT} Arkbuild/opt/ppsspp/assets/gamecontrollerdb.txt
if [ -f "ppsspp/ppsspp.sh.${UNIT}" ]; then
  sudo cp ppsspp/ppsspp.sh.${UNIT} Arkbuild/usr/local/bin/ppsspp.sh
else
  sudo cp ppsspp/ppsspp.sh Arkbuild/usr/local/bin/
fi
sudo cp -R ppsspp/configs/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini.go.${UNIT} Arkbuild/opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini.go
sudo cp -R ppsspp/configs/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini.sdl.${UNIT} Arkbuild/opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini.sdl
sudo cp ppsspp/controls.ini.${UNIT} Arkbuild/opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM/controls.ini
sudo cp ppsspp/ppsspp.ini.${UNIT} Arkbuild/opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini
sudo cp ppsspp/configs/backupforromsfolder/ppsspp/PSP/SYSTEM/*_ppsspp.ini Arkbuild/opt/ppsspp/backupforromsfolder/ppsspp/PSP/SYSTEM/
call_chroot "chown -R ark:ark /opt/"
sudo chmod 777 Arkbuild/opt/ppsspp/PPSSPPSDL
sudo chmod 777 Arkbuild/usr/local/bin/ppsspp.sh
