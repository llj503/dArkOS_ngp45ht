#!/bin/bash

# Build and install PPSSPP standalone emulator
if [ -f "Arkbuild_package_cache/${CHIPSET}/ppsspp-2021.tar.gz" ]; then
    sudo tar -xvzpf Arkbuild_package_cache/${CHIPSET}/ppsspp-2021.tar.gz
    if [ ! -f "Arkbuild/opt/ppsspp-2021/PPSSPPSDL" ]; then
        echo "WARNING: PPSSPP-2021 cache tarball is incomplete, rebuilding from source..."
        sudo rm -f Arkbuild_package_cache/${CHIPSET}/ppsspp-2021.tar.gz
    fi
fi
if [ ! -f "Arkbuild/opt/ppsspp-2021/PPSSPPSDL" ] && [ ! -f "Arkbuild_package_cache/${CHIPSET}/ppsspp-2021.tar.gz" ]; then
	call_chroot "cd /home/ark &&
	  cd ${CHIPSET}_core_builds &&
	  chmod 777 builds-alt.sh &&
	  eatmydata ./builds-alt.sh ppsspp-2021
	  "
	sudo mkdir -p Arkbuild/opt/ppsspp-2021
	sudo cp -Ra Arkbuild/home/ark/${CHIPSET}_core_builds/ppsspp-2021/build/assets/ Arkbuild/opt/ppsspp-2021/
	sudo cp -a Arkbuild/home/ark/${CHIPSET}_core_builds/ppsspp-2021/LICENSE.TXT Arkbuild/opt/ppsspp-2021/
	sudo cp -a Arkbuild/home/ark/${CHIPSET}_core_builds/ppsspp-2021/build/PPSSPPSDL Arkbuild/opt/ppsspp-2021/
	if [ -f "Arkbuild_package_cache/${CHIPSET}/ppsspp-2021.tar.gz" ]; then
	  sudo rm -f Arkbuild_package_cache/${CHIPSET}/ppsspp-2021.tar.gz
	fi
	sudo tar -czpf Arkbuild_package_cache/${CHIPSET}/ppsspp-2021.tar.gz Arkbuild/opt/ppsspp-2021/
fi
sudo cp ppsspp/gamecontrollerdb.txt.${UNIT} Arkbuild/opt/ppsspp-2021/assets/gamecontrollerdb.txt
# Own config set, so PPSSPP-2021 no longer shares ppsspp.ini with the current
# PPSSPP (upstream 596c142); ppsspp.sh copies it to /roms/psp/ppsspp-2021.
sudo mkdir -p Arkbuild/opt/ppsspp-2021/backupforromsfolder/ppsspp/PSP/SYSTEM
sudo cp ppsspp/configs/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini.go.${UNIT} Arkbuild/opt/ppsspp-2021/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini.go
sudo cp ppsspp/configs/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini.2021.sdl.${UNIT} Arkbuild/opt/ppsspp-2021/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini.sdl
sudo cp ppsspp/controls.ini.${UNIT} Arkbuild/opt/ppsspp-2021/backupforromsfolder/ppsspp/PSP/SYSTEM/controls.ini
sudo cp ppsspp/ppsspp.ini.2021.${UNIT} Arkbuild/opt/ppsspp-2021/backupforromsfolder/ppsspp/PSP/SYSTEM/ppsspp.ini
call_chroot "chown -R ark:ark /opt/"
sudo chmod 777 Arkbuild/opt/ppsspp-2021/PPSSPPSDL
