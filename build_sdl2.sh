#!/bin/bash

if [ "$CHIPSET" == "rk3326" ]; then
  sub_folder=""
else
  sub_folder="build"
fi

if [ "$1" == "32" ]; then
  BITNESS="32"
  ARCH="arm-linux-gnueabihf"
  CHROOT_DIR="Arkbuild32"
else
  BITNESS="64"
  ARCH="aarch64-linux-gnu"
  CHROOT_DIR="Arkbuild"
fi

# For portrait-panel devices (e.g. rg52mini with 720x1280 DSI panel),
# inject RGA rotation patches before building SDL2. These patches make
# SDL2 create landscape GBM surfaces and use the Rockchip RGA hardware
# to rotate each frame 270 degrees before scanout to the portrait panel.
# Patches are renamed to avoid the "odroidgoa" skip logic in sdl2.sh.
# Every script that needs core_builds inside a chroot clones it from
# christianhaitian if the directory is absent, and this is the first one to run,
# so whatever it leaves behind is what all the later ones use. For rk3562 that
# is the wrong tree: it is the upstream of our fork, with the Cortex-A55 build
# flags and the miniloong patches whose hunks collide with our rotation patch.
# The 64-bit chroot gets the fork copied in by build_rg52mini.sh; the 32-bit one
# had nothing doing that until build_retroarch.sh, far too late and only when
# RetroArch32 is not restored from cache. Settle it here, for whichever chroot
# is current, before anything else has a chance to clone the wrong one.
if [ "$CHIPSET" == "rk3562" ]; then
  # A marker file, not a check of the git remote: the copy carries the
  # submodule's .git, which is a file pointing into the superproject's
  # .git/modules and resolves to nothing inside a chroot. Asking such a copy
  # where it came from fails, so the comparison would never settle and the
  # tree would be re-copied on every build.
  CB_DIR=${CHROOT_DIR}/home/ark/${CHIPSET}_core_builds
  if [ ! -f "${CB_DIR}/.darkos-local-fork" ]; then
    echo "Replacing ${CHROOT_DIR}'s core_builds with the local rk3562 fork..."
    sudo rm -rf ${CB_DIR}
    sudo mkdir -p ${CHROOT_DIR}/home/ark
    sudo cp -a rk3562_core_builds ${CB_DIR}
    sudo touch ${CB_DIR}/.darkos-local-fork
    sudo chown -R 1000:1000 ${CB_DIR}
  fi
fi

if [ "$UNIT" == "rg52mini" ]; then
  echo "Injecting RGA screen rotation patches for portrait panel..."
  # Ensure core_builds is cloned first so we can add patches
  sudo chroot ${CHROOT_DIR}/ bash -c "source /root/.bashrc && cd /home/ark &&
    if [ ! -d ${CHIPSET}_core_builds ]; then git clone https://github.com/christianhaitian/${CORE_BUILDS_CHIPSET}_core_builds.git ${CHIPSET}_core_builds; fi
    "
  sudo cp sdl2-patch-0004-odroidgoa-kmsdrm.patch ${CHROOT_DIR}/home/ark/${CHIPSET}_core_builds/patches/sdl2-patch-0005-kmsdrm-rotation.patch
  sudo cp sdl2-patch-0005-odroidgoa-rotate-cursor.patch ${CHROOT_DIR}/home/ark/${CHIPSET}_core_builds/patches/sdl2-patch-0006-rotate-cursor.patch
  # Scaled fullscreen modes (960x540 ... 640x360), scaled onto the panel by
  # the same RGA pass that rotates; needs the rotation patch above.
  sudo cp sdl2-patch-0008-kmsdrm-scaled-modes.patch ${CHROOT_DIR}/home/ark/${CHIPSET}_core_builds/patches/sdl2-patch-0008-kmsdrm-scaled-modes.patch
fi

# Build and install SDL2
if [ "$ARCH" == "arm-linux-gnueabihf" ]; then
  sudo chroot ${CHROOT_DIR}/ bash -c "source /root/.bashrc && cd /home/ark &&
    export CFLAGS=\"-Wno-error=int-conversion\" &&
    if [ ! -d ${CHIPSET}_core_builds ]; then git clone https://github.com/christianhaitian/${CORE_BUILDS_CHIPSET}_core_builds.git ${CHIPSET}_core_builds; fi &&
    cd ${CHIPSET}_core_builds &&
    chmod 777 builds-alt.sh &&
    eatmydata ./builds-alt.sh sdl2 &&
    cd SDL/${sub_folder} &&
    make install
    "
else
  sudo chroot ${CHROOT_DIR}/ bash -c "source /root/.bashrc && cd /home/ark &&
    if [ ! -d ${CHIPSET}_core_builds ]; then git clone https://github.com/christianhaitian/${CORE_BUILDS_CHIPSET}_core_builds.git ${CHIPSET}_core_builds; fi &&
    cd ${CHIPSET}_core_builds &&
    chmod 777 builds-alt.sh &&
    eatmydata ./builds-alt.sh sdl2 &&
    cd SDL/build &&
    make install
    "
fi

extension=$(grep -oP '(?<=extension=").*?(?=")' ${CHROOT_DIR}/home/ark/${CHIPSET}_core_builds/scripts/sdl2.sh)
if [[ "$UNIT" != *"rgb10"* ]] && [ "$UNIT" != "rk2020" ] && [ "$CHIPSET" == "rk3326" ]; then
  sudo chroot ${CHROOT_DIR}/ bash -c "cp -f /home/ark/${CHIPSET}_core_builds/sdl2-${BITNESS}/libSDL2-2.0.so.0.$extension /usr/lib/${ARCH}/."
fi
sudo chroot ${CHROOT_DIR}/ bash -c "ln -sfv /usr/lib/${ARCH}/libSDL2.so /usr/lib/${ARCH}/libSDL2-2.0.so.0"
sudo chroot ${CHROOT_DIR}/ bash -c "ln -sfv /usr/lib/${ARCH}/libSDL2-2.0.so.0.${extension} /usr/lib/${ARCH}/libSDL2.so"
sudo chroot ${CHROOT_DIR}/ bash -c "ln -sfv /usr/include/SDL2 /usr/local/include/"
sudo chroot ${CHROOT_DIR}/ bash -c "rm -f /usr/bin/sdl2-config"
sudo chroot ${CHROOT_DIR}/ bash -c "ln -sfv /usr/lib/aarch64-linux-gnu/bin/sdl2-config /usr/bin/sdl2-config"
sudo cp -R ${CHROOT_DIR}/home/ark/${CHIPSET}_core_builds/SDL/include/* ${CHROOT_DIR}/usr/include/${ARCH}/SDL2/
sudo rm -rf ${CHROOT_DIR}/home/ark/${CHIPSET}_core_builds/SDL
