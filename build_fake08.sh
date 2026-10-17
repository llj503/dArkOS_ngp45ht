#!/bin/bash

# Build and install fake08 standalone emulator
# The upstream source commit alone is the wrong key for this fork: our changes
# live in the recipe, not in the emulator's sources, so the key never moves and
# a stale binary is restored over them. That is how the -Ofast this component
# needs would have been silently dropped. Fold the recipe into the key, the way
# build_flycastsa.sh already does.
FAKE08_RECIPE_SHA=$(sha1sum ${CHIPSET}_core_builds/scripts/fake08sa.sh 2>/dev/null | cut -c1-12)
if [ -f "Arkbuild_package_cache/${CHIPSET}/fake08.tar.gz" ] && [ "$(cat Arkbuild_package_cache/${CHIPSET}/fake08.commit)" == "$(curl -s https://api.github.com/repos/jtothebell/fake-08/commits/master | jq -r '.sha')-${FAKE08_RECIPE_SHA}" ]; then
    sudo tar -xvzpf Arkbuild_package_cache/${CHIPSET}/fake08.tar.gz
else
	call_chroot "source /root/.bashrc && cd /home/ark &&
	  cd ${CHIPSET}_core_builds &&
	  chmod 777 builds-alt.sh &&
	  eatmydata ./builds-alt.sh fake08sa &&
	  mkdir -p /opt/fake08 &&
	  cp fake08sa-64/fake08 /opt/fake08/
	  "
	if [ -f "Arkbuild_package_cache/${CHIPSET}/fake08.tar.gz" ]; then
	  sudo rm -f Arkbuild_package_cache/${CHIPSET}/fake08.tar.gz
	fi
	if [ -f "Arkbuild_package_cache/${CHIPSET}/fake08.commit" ]; then
	  sudo rm -f Arkbuild_package_cache/${CHIPSET}/fake08.commit
	fi
	sudo tar -czpf Arkbuild_package_cache/${CHIPSET}/fake08.tar.gz Arkbuild/opt/fake08/
	echo "$(sudo git --git-dir=Arkbuild/home/ark/${CHIPSET}_core_builds/fake-08sa/.git --work-tree=Arkbuild/home/ark/${CHIPSET}_core_builds/fake-08sa rev-parse HEAD)-${FAKE08_RECIPE_SHA}" > Arkbuild_package_cache/${CHIPSET}/fake08.commit
fi

call_chroot "chown -R ark:ark /opt/"
sudo chmod 777 Arkbuild/opt/fake08/fake08
sudo cp pico8/pico8.sh Arkbuild/usr/local/bin/pico8.sh
sudo cp pico8/fake08.gptk Arkbuild/opt/fake08/
sudo chmod 777 Arkbuild/usr/local/bin/pico8.sh
