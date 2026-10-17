#!/bin/bash

# Build and install VK_LAYER_DARKOS_rotate (vk-rotate-layer/), an implicit
# Vulkan layer. Vulkan programs presenting through VK_KHR_display - RetroArch
# on the Vulkan driver, PortMaster ports on SDL's KMSDRM Vulkan path - got the
# portrait 720x1280 panel as it is and drew a stretched, sideways picture. The
# layer shows them a landscape 1280x720 display and turns each frame onto the
# panel with a small GPU pass. It does nothing on a landscape display.
# See docs/KNOWN-ISSUES.md.
install_package 64 libvulkan-dev glslang-tools
sudo rm -rf Arkbuild/tmp/vk-rotate-layer
sudo cp -r vk-rotate-layer Arkbuild/tmp/
call_chroot "cd /tmp/vk-rotate-layer && sh build.sh"
if [ -f Arkbuild/tmp/vk-rotate-layer/libVkLayer_DARKOS_rotate.so ]; then
  sudo install -m 644 Arkbuild/tmp/vk-rotate-layer/libVkLayer_DARKOS_rotate.so Arkbuild/usr/lib/aarch64-linux-gnu/
  sudo mkdir -p Arkbuild/usr/share/vulkan/implicit_layer.d
  sudo install -m 644 vk-rotate-layer/VkLayer_DARKOS_rotate.json Arkbuild/usr/share/vulkan/implicit_layer.d/
else
  echo "WARNING: VK_LAYER_DARKOS_rotate did not build; Vulkan programs will present sideways."
fi
sudo rm -rf Arkbuild/tmp/vk-rotate-layer
