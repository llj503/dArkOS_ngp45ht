#!/bin/bash

# Build and install Yabasanshiro standalone emulator
#
# The cache key used to be read from christianhaitian's copy of this recipe
# over the network. That is the upstream of our fork, so editing the TAG
# left the key unchanged and a stale tarball was restored over the new
# work - while a network hiccup silently forced a rebuild. Read our own.
YABA_CACHE_KEY="$(grep -oP '(?<=TAG=").*?(?=")' ${CHIPSET}_core_builds/scripts/yabasanshirosa.sh)"
if [ -f "Arkbuild_package_cache/${CHIPSET}/yabasanshirosa.tar.gz" ] && [ "$(cat Arkbuild_package_cache/${CHIPSET}/yabasanshirosa.commit)" == "${YABA_CACHE_KEY}" ]; then
    sudo tar -xvzpf Arkbuild_package_cache/${CHIPSET}/yabasanshirosa.tar.gz
else
	call_chroot "source /root/.bashrc && cd /home/ark &&
	  cd ${CHIPSET}_core_builds &&
	  chmod 777 builds-alt.sh &&
	  sed -i '/python-pip/s//python3-pip/g' scripts/yabasanshirosa.sh &&
	  eatmydata ./builds-alt.sh yabasanshirosa &&
	  mkdir -p /opt/yabasanshiro &&
	  cp yabasanshirosa64/yabasanshiro /opt/yabasanshiro/
	  "
	if [ -f "Arkbuild_package_cache/${CHIPSET}/yabasanshirosa.tar.gz" ]; then
	  sudo rm -f Arkbuild_package_cache/${CHIPSET}/yabasanshirosa.tar.gz
	fi
	if [ -f "Arkbuild_package_cache/${CHIPSET}/yabasanshirosa.commit" ]; then
	  sudo rm -f Arkbuild_package_cache/${CHIPSET}/yabasanshirosa.commit
	fi
	# Never cache a build that produced nothing: the key would still match
	# and every later build would restore the failure instead of retrying.
	if sudo test -s Arkbuild/opt/yabasanshiro/yabasanshiro; then
	  sudo tar -czpf Arkbuild_package_cache/${CHIPSET}/yabasanshirosa.tar.gz Arkbuild/opt/yabasanshiro/
	  echo "${YABA_CACHE_KEY}" > Arkbuild_package_cache/${CHIPSET}/yabasanshirosa.commit
	else
	  echo "Yabasanshiro produced no binary - not caching, so the next build retries."
	fi
fi
call_chroot "chown -R ark:ark /opt/"
sudo chmod 777 Arkbuild/opt/yabasanshiro/yabasanshiro
sudo cp yabasanshiro/saturn.sh Arkbuild/usr/local/bin/saturn.sh
sudo chmod 777 Arkbuild/usr/local/bin/saturn.sh
