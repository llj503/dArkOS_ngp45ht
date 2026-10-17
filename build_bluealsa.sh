#!/bin/bash

# Not really building bluez-alsa, just installing it from the debian repo
if [ -f "Arkbuild_package_cache/${CHIPSET}/bluealsa.tar.gz" ]; then
    sudo tar -xvzpf Arkbuild_package_cache/${CHIPSET}/bluealsa.tar.gz
else
	call_chroot "apt update -y &&
	  apt install -y automake bluez libasound2-dev libbluetooth-dev libfdk-aac-dev libldacbt-abr-dev libldacbt-enc-dev libsbc-dev libdbus-1-dev libglib2.0-dev libopenaptx-dev libsbc-dev libspa-0.2-bluetooth pkg-config python3-docutils &&
	  cd /usr/bin &&
	  wget -t 3 -T 60 --no-check-certificate https://github.com/christianhaitian/RG353VKernel/raw/refs/heads/main/wifibt/rtk_hciattach &&
	  chmod 777 rtk_hciattach &&
	  cd /lib/firmware &&
	  wget -t 3 -T 60 --no-check-certificate https://github.com/christianhaitian/RG353VKernel/raw/refs/heads/main/wifibt/rtl8821c_fw &&
	  wget -t 3 -T 60 --no-check-certificate https://github.com/christianhaitian/RG353VKernel/raw/refs/heads/main/wifibt/rtl8821cs_config &&
	  mv rtl8821cs_config rtl8821c_config &&
	  cd /home/ark/${CHIPSET}_core_builds &&
	  git clone https://github.com/arkq/bluez-alsa.git &&
	  cd bluez-alsa &&
	  git checkout -b v4.3.1 &&
	  autoreconf --install --force &&
	  mkdir build &&
	  cd build &&
	  ../configure --enable-aptx --enable-aptx-hd --with-libopenaptx --enable-aac --enable-ldac --enable-upower --enable-a2dpconf --enable-systemd &&
	  make CFLAGS=\"-Ofast -s\" -j$(nproc) &&
	  make install &&
	  apt remove -y libasound2-dev libbluetooth-dev libsbc-dev libfdk-aac-dev libldacbt-abr-dev libldacbt-enc-dev libsbc-dev libdbus-1-dev libglib2.0-dev libopenaptx-dev
	  "
	if [ -f "Arkbuild_package_cache/${CHIPSET}/bluealsa.tar.gz" ]; then
	  sudo rm -f Arkbuild_package_cache/${CHIPSET}/bluealsa.tar.gz
	fi
	sudo tar -czpf Arkbuild_package_cache/${CHIPSET}/bluealsa.tar.gz Arkbuild/usr/lib/aarch64-linux-gnu/alsa-lib/ Arkbuild/usr/bin/{a2dpconf,bluealsa-aplay,bluealsactl,bluealsad} Arkbuild/usr/share/dbus-1/interfaces/org.bluealsa.xml Arkbuild/usr/share/dbus-1/system.d/org.bluealsa.conf
fi
sudo cp bluetooth/scripts/Bluetooth.sh Arkbuild/opt/system/
sudo cp bluetooth/scripts/bt* Arkbuild/usr/local/bin/
sudo cp bluetooth/scripts/enable_bluetooth.sh Arkbuild/usr/local/bin/
sudo cp bluetooth/scripts/watchforbtaudio.sh Arkbuild/usr/local/bin/
sudo cp bluetooth/systemd/* Arkbuild/etc/systemd/system/
sudo mkdir -p Arkbuild/etc/alsa/conf.d
sudo cp bluetooth/config/20-bluealsa.conf Arkbuild/etc/alsa/conf.d/
sudo chmod 777 Arkbuild/usr/local/bin/*
sudo chmod -R 777 Arkbuild/opt/system/
call_chroot "chown -R ark:ark /opt"
call_chroot "systemctl disable watchforbtaudio bluetooth bluealsa enable_bluetooth"
