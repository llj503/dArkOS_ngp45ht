#!/bin/bash

# Build and install DuckStation standalone emulator.
#
# As of DuckStation 0.1-10xxx, upstream removed the NoGUI/SDL frontend the old
# recipe compiled (rk3562_core_builds pins the 2022 commit 5ab5070d7). Modern
# DuckStation ships a self-contained AppImage with a built-in fullscreen ImGui
# UI and native Vulkan, so we mirror christianhaitian/dArkOS and install the
# prebuilt AppImage instead of compiling from rk3562_core_builds.
#
# The AppImage self-mounts a squashfs via FUSE (CONFIG_FUSE_FS=y in our kernel,
# libfuse2 in needed_packages.txt). Config lives at the XDG path
# ~/.local/share/duckstation/. Portrait rotation for the RG52 Mini is handled by
# [Display] Rotation = Rotate90 in settings.ini.rg52mini (no source patch, unlike
# flycast) — the AppImage bundles its own SDL3, so our SDL2 RGA rotation does not
# apply to it. Its SDL3 asks Vulkan for a 720x1280 mode, and VK_LAYER_DARKOS_rotate
# hands it the panel as it is, nothing turned (docs/KNOWN-ISSUES.md).

DUCKSTATION_APPIMAGE="duckstation/duckstation-sa-0.1-10495.AppImage"

sudo mkdir -p Arkbuild/opt/duckstation
sudo mkdir -p Arkbuild/home/ark/.local/share/duckstation
sudo cp "${DUCKSTATION_APPIMAGE}" Arkbuild/opt/duckstation/duckstationsa
sudo cp duckstation/scripts/standalone-duckstation Arkbuild/usr/local/bin/
sudo cp duckstation/configs/settings.ini.${UNIT} Arkbuild/home/ark/.local/share/duckstation/settings.ini
# Install our controller DB to DuckStation's data root (EmuFolders::DataRoot,
# read in preference to the AppImage's bundled gamecontrollerdb.txt) so SDL3
# recognizes the built-in rk3562-joystick as a gamepad. vendor/product=0 means
# SDL derives a name-based GUID. NOTE: DuckStation bundles SDL3, which enumerates this pad's
# raw buttons differently than SDL2, so it needs the SDL3-order entry (a:b0,b:b1). Use the
# DuckStation-specific db -- NOT inttools/ (which carries the SDL2 order for gptokeyb et al,
# and would swap A/B here).
sudo cp duckstation/configs/gamecontrollerdb.txt Arkbuild/home/ark/.local/share/duckstation/gamecontrollerdb.txt
call_chroot "chown -R ark:ark /opt/"
call_chroot "chown -R ark:ark /home/ark/"
sudo chmod 777 Arkbuild/opt/duckstation/duckstationsa
sudo chmod 777 Arkbuild/usr/local/bin/standalone-duckstation
