#!/bin/bash

# Build and install flycast standalone emulator
# Cache key: hash of the flycastsa recipe AND its patches (which the recipe copies
# from the working tree). Keying on the recipe alone would miss patch-only changes
# (e.g. the rg52mini 270-degree rotation patch) and silently reuse a stale build.
FLYCASTSA_RECIPE_SHA=$(cat rk3562_core_builds/scripts/flycastsa.sh rk3562_core_builds/patches/flycastsa-patch* 2>/dev/null | sha1sum | awk '{print $1}')
if [ -f "Arkbuild_package_cache/${CHIPSET}/flycastsa.tar.gz" ] && \
   [ "$(cat Arkbuild_package_cache/${CHIPSET}/flycastsa.commit 2>/dev/null)" == "${FLYCASTSA_RECIPE_SHA}" ]; then
    sudo tar -xvzpf Arkbuild_package_cache/${CHIPSET}/flycastsa.tar.gz
else
	call_chroot "cd /home/ark &&
	  cd ${CHIPSET}_core_builds &&
	  chmod 777 builds-alt.sh &&
	  eatmydata ./builds-alt.sh flycastsa
	  "
	sudo mkdir -p Arkbuild/opt/flycastsa
	if [[ "$CHIPSET" = "rk3326" ]]; then
	  ext="-rk3326"
	else
	  ext=""
	fi
	sudo cp -R Arkbuild/home/ark/${CHIPSET}_core_builds/flycastsa-64/flycast${ext} Arkbuild/opt/flycastsa/flycast
	sudo rm -f Arkbuild_package_cache/${CHIPSET}/flycastsa.tar.gz Arkbuild_package_cache/${CHIPSET}/flycastsa.commit
	sudo tar -czpf Arkbuild_package_cache/${CHIPSET}/flycastsa.tar.gz Arkbuild/opt/flycastsa/
	echo "${FLYCASTSA_RECIPE_SHA}" | sudo tee Arkbuild_package_cache/${CHIPSET}/flycastsa.commit > /dev/null
fi

sudo mkdir -p Arkbuild/home/ark/.config/flycast
sudo cp flycast/config/emu.cfg Arkbuild/home/ark/.config/flycast/

# RG52 Mini portrait panel: run flycast in Vulkan, which VK_LAYER_DARKOS_rotate
# turns onto the panel (build_vkrotate.sh). flycast links the system SDL2
# (USE_HOST_SDL in the recipe; on Linux it would build its own static copy).
# Our SDL shows it a landscape 1280x720 display, which matches the mode the
# layer reports, and turns its GL fallback with the RGA. The window is
# 1280x720 as well, so that flycast presents at the panel's own size. With the
# shipped 640x480 SDL looks for a Vulkan display mode of that size: the driver
# cannot make one, and before the layer's scaled modes flycast fell back to GL
# (upright, but not Vulkan); now it would get a 640x480 picture scaled up to
# 960x720. With its own SDL it saw the panel's
# 720x1280, found no such Vulkan display mode, fell back to GL, and drew
# sideways or, with Rotate90, upside down. Before the layer,
# Rotate90=yes with flycastsa-patch-004 rotated Vulkan; with the layer that
# would rotate twice, so Rotate90 stays off.
# Landscape devices (rg43h) and other chipsets keep the GL default (pvr.rend=0,
# Rotate90=no) where SDL2 handles rotation.
if [ "$UNIT" == "rg52mini" ]; then
  sudo sed -i 's/^pvr.rend = .*/pvr.rend = 4/'           Arkbuild/home/ark/.config/flycast/emu.cfg
  sudo sed -i 's/^rend.Rotate90 = .*/rend.Rotate90 = no/' Arkbuild/home/ark/.config/flycast/emu.cfg
  sudo sed -i '/^\[window\]/,/^\[/{s/^width = .*/width = 1280/;s/^height = .*/height = 720/}' Arkbuild/home/ark/.config/flycast/emu.cfg
fi

call_chroot "chown -R ark:ark /opt/"
call_chroot "chown -R ark:ark /home/ark/.config/flycast/"
sudo chmod 777 Arkbuild/opt/flycastsa/flycast
