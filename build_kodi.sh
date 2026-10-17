#!/bin/bash

# Build and install Kodi
KODI_VERSION_TAG=21.3-Omega

# Per-UNIT build cache. The RG52 Mini binary is RGA-rotated at compile time
# (-DKODI_GBM_ROTATE=90, see below) while the RG43H is not, so the two devices
# produce different /opt/kodi trees. Key the cache per-UNIT (kodi_${UNIT}.tar.gz)
# and fold the rotation state into the .commit key so both copies are retained
# and flipping the rotation invalidates only the affected entry — same scheme as
# build_ppssppsa.sh (ppsspp_${UNIT}.tar.gz).
if [ "$UNIT" == "rg52mini" ]; then
  KODI_ROT=90
else
  KODI_ROT=0
fi
KODI_CACHE_KEY="${KODI_VERSION_TAG}-${UNIT}-rot${KODI_ROT}-mali-egl3"
mkdir -p Arkbuild_package_cache/${CHIPSET}

# Install additional Kodi build dependencies
if test -z "$(cat Arkbuild/etc/apt/sources.list | grep ${DEBIAN_CODE_NAME}-backports)"
then
    echo "deb http://deb.debian.org/debian ${DEBIAN_CODE_NAME}-backports main" | sudo tee -a Arkbuild/etc/apt/sources.list
    call_chroot "apt -y update"
fi

# Kodi links against libavcodec/libavformat/etc — make sure our rkmpp ffmpeg
# libraries are in place before the Kodi build (and in the image on a cache hit).
# Skip if BUILD_RKMPP_FFMPEG=y already ran build_ffmpeg.sh from the master script.
if [[ "$BUILD_RKMPP_FFMPEG" == "y" ]] && [ ! -f Arkbuild/usr/lib/aarch64-linux-gnu/librockchip_mpp.so.1 ]; then
  source ./build_ffmpeg.sh
fi

if [ -f "Arkbuild_package_cache/${CHIPSET}/kodi_${UNIT}.tar.gz" ] && [ "$(cat Arkbuild_package_cache/${CHIPSET}/kodi_${UNIT}.commit)" == "${KODI_CACHE_KEY}" ]; then
    # ---- Cache hit: extract the prebuilt /opt/kodi tree ----
    echo "Using cached Kodi build (${KODI_CACHE_KEY})"
    sudo tar -xvzpf Arkbuild_package_cache/${CHIPSET}/kodi_${UNIT}.tar.gz
    # The build-time -dev packages are not cached and were removed at the end of
    # the build that produced the cache, but the runtime shared libraries Kodi
    # links against are not dpkg-tracked for kodi-gbm — install just the runtime
    # (lib*, non -dev) packages and mark them manual so cleanup_filesystem.sh's
    # autoremove leaves them in place.
    while read KODI_NEEDED_DEV_PACKAGE; do
      if [[ ! "$KODI_NEEDED_DEV_PACKAGE" =~ ^# ]] && [[ "$KODI_NEEDED_DEV_PACKAGE" == lib* ]] && [[ "$KODI_NEEDED_DEV_PACKAGE" != *"-dev"* ]]; then
        install_package 64 "${KODI_NEEDED_DEV_PACKAGE}"
        call_chroot "apt-mark manual ${KODI_NEEDED_DEV_PACKAGE}"
      fi
    done <kodi_needed_dev_packages.txt
else
    # ---- Cache miss: full build from source ----
    while read KODI_NEEDED_DEV_PACKAGE; do
      if [[ ! "$KODI_NEEDED_DEV_PACKAGE" =~ ^# ]]; then
        install_package 64 "${KODI_NEEDED_DEV_PACKAGE}"
      fi
    done <kodi_needed_dev_packages.txt

    # Protect Kodi's runtime shared libraries from cleanup_filesystem.sh's
    # `apt -y autoremove`. Some runtime libs (e.g. libtinyxml2.6.2v5) only enter the
    # chroot as auto-marked dependencies of the -dev packages we remove at the end of
    # this script. install_package skips already-present packages, so they stay
    # auto-marked; once the -dev package is removed they're orphaned and autoremove
    # strips them — and kodi-gbm (not a dpkg package) then fails to start with a
    # missing .so. Mark the runtime (lib*, non -dev) packages manual so they survive.
    while read KODI_NEEDED_DEV_PACKAGE; do
      if [[ ! "$KODI_NEEDED_DEV_PACKAGE" =~ ^# ]] && [[ "$KODI_NEEDED_DEV_PACKAGE" == lib* ]] && [[ "$KODI_NEEDED_DEV_PACKAGE" != *"-dev"* ]]; then
        call_chroot "apt-mark manual ${KODI_NEEDED_DEV_PACKAGE}"
      fi
    done <kodi_needed_dev_packages.txt

    # Pre-seed flaky upstream addon download tarballs. Some Kodi addons build their
    # own deps from source (e.g. inputstream.ffmpegdirect → ffmpeg → gnutls → nettle
    # → gmp) and fetch tarballs from unreliable hosts (gmplib.org drops connections,
    # curl status 56). Any file in kodi_dl_cache/ is copied into the addon download
    # dir before the build; ExternalProject hash-verifies it and skips the network.
    sudo mkdir -p Arkbuild/home/ark/kodi_dl_cache
    sudo cp -f kodi_dl_cache/* Arkbuild/home/ark/kodi_dl_cache/ 2>/dev/null || true
    sudo tee Arkbuild/home/ark/preseed_addon_dl.sh >/dev/null <<'PRESEED'
#!/bin/bash
DL="/home/ark/kodi/kodi-source/tools/depends/target/binary-addons/native/build/download"
mkdir -p "$DL"
cp -fv /home/ark/kodi_dl_cache/* "$DL"/ 2>/dev/null || true
PRESEED
    sudo chmod +x Arkbuild/home/ark/preseed_addon_dl.sh

    # Clone christianhaitian's kodi-install and apply the standard ArkOS seds.
    # The actual build (./ArkOS-Kodi-Build-alt.sh) is split out below so the RG52
    # Mini rotation patch can be staged into kodi-install/patches/ after the clone
    # but before the build script's `patch -Np1 patches/*.patch` loop runs.
    call_chroot "cd /home/ark &&
      mkdir -p kodi &&
      cd kodi &&
      git clone --recursive https://github.com/christianhaitian/kodi-install &&
      cd kodi-install &&
      sed -i '/\/home\/kodi/s//\/home\/ark\/kodi/' configuration.sh &&
      sed -i '/^cmake \.\.\/kodi-source/ s#\$# -DCMAKE_EXE_LINKER_FLAGS=-Wl,--copy-dt-needed-entries#' ArkOS-Kodi-Build-alt.sh &&
      sed -i '/binary-addons PREFIX/i bash /home/ark/preseed_addon_dl.sh' ArkOS-Kodi-Build-alt.sh &&
      chmod 777 ArkOS-Kodi-Build-alt.sh
      "

    # kodi-install is cloned at master, and it has grown patches of its own that
    # now land on the same files as ours.  Both failures in the build log come
    # from that:
    #
    #   0017-kodi-patch-mali-egl-display is our own kodi-patch-002 - upstream
    #   adopted it ("Fix egl for g29p1 blob thanks to patch from bmdhacks dArkOS
    #   rg52mini repo", 25d99273).  Applying both makes patch report the second
    #   one as already applied.
    #
    #   0016-miniloong-internal-only-rotate270 rotates a different device's panel
    #   the other way and edits the same DRM paths our 90-degree rotation does.
    #   That is the hunk that actually fails, and with it Kodi never builds:
    #   "DRMAtomic.cpp Hunk #1 FAILED" then "tar: Arkbuild/opt/kodi: Cannot stat".
    #
    # Drop both and keep ours, the same way build_retroarch.sh drops the
    # miniloong patches from the 32-bit core_builds.
    sudo rm -f Arkbuild/home/ark/kodi/kodi-install/patches/0016-miniloong-internal-only-rotate270.patch
    sudo rm -f Arkbuild/home/ark/kodi/kodi-install/patches/0017-kodi-patch-mali-egl-display.patch

    # All RK3562 devices: fix EGL display init for Mali g29p1. Kodi hardcodes
    # EGL_MESA_platform_gbm which Mali doesn't advertise; fallback eglGetDisplay
    # with a GBM device pointer also fails. Patch uses EGL_KHR_platform_gbm
    # (same enum, non-Mesa name) and adds EGL_DEFAULT_DISPLAY as final fallback.
    if [ "$CHIPSET" == "rk3562" ]; then
      sudo cp kodi-patch-002-mali-egl-display.patch Arkbuild/home/ark/kodi/kodi-install/patches/
    fi

    # RG52 Mini only: software-rotate kodi-gbm 90° via the Rockchip RGA. kodi-gbm
    # talks to GBM/KMS directly and bypasses the patched SDL2 that rotates every
    # other app, so on the portrait (720x1280) panel the GUI comes out sideways.
    # (1) Stage the RGA rotation patch — ArkOS-Kodi-Build-alt.sh applies every
    #     patches/*.patch with `patch -Np1` to the fresh kodi-source clone.
    # (2) Compile the rotation path in via -DKODI_GBM_ROTATE=90 (appended to the
    #     same cmake line as the linker flag above). Without the define, the patch
    #     compiles to an inert stub with no librga dependency (RG43H is untouched).
    if [ "$UNIT" == "rg52mini" ]; then
      sudo cp kodi-patch-001-rk3562-rga-rotation.patch Arkbuild/home/ark/kodi/kodi-install/patches/
      call_chroot "cd /home/ark/kodi/kodi-install && sed -i '/^cmake \.\.\/kodi-source/ s#\$# -DKODI_GBM_ROTATE=90#' ArkOS-Kodi-Build-alt.sh"
    fi

    # Build Kodi.
    call_chroot "cd /home/ark/kodi/kodi-install && ./ArkOS-Kodi-Build-alt.sh ${KODI_VERSION_TAG}"

    # Cache the built /opt/kodi tree before any per-device userdata is laid down,
    # so the cached binary stays device-config-agnostic.
    if [ -f "Arkbuild_package_cache/${CHIPSET}/kodi_${UNIT}.tar.gz" ]; then
      sudo rm -f Arkbuild_package_cache/${CHIPSET}/kodi_${UNIT}.tar.gz
    fi
    if [ -f "Arkbuild_package_cache/${CHIPSET}/kodi_${UNIT}.commit" ]; then
      sudo rm -f Arkbuild_package_cache/${CHIPSET}/kodi_${UNIT}.commit
    fi
    # Only cache a build that produced something. Without this check a failed
    # build stores a 45-byte tarball under a key that still matches, and every
    # later build restores the failure instead of retrying it - which is what
    # happened to Kodi, bluealsa, freej2me-plus, yabasanshiro, ecwolf and
    # gametank between 2026-09-15 and 2026-09-16, silently. Test for an ELF
    # rather than a named binary, the same way scripts/audit-components.sh does.
    if sudo find Arkbuild/opt/kodi -type f -exec head -c4 {} \; 2>/dev/null \
         | grep -qa $'\x7fELF'; then
      sudo tar -czpf Arkbuild_package_cache/${CHIPSET}/kodi_${UNIT}.tar.gz Arkbuild/opt/kodi/
      echo "${KODI_CACHE_KEY}" > Arkbuild_package_cache/${CHIPSET}/kodi_${UNIT}.commit
    else
      echo "Kodi produced no binary - not caching, so the next build retries."
      echo "The audit at the end of this build will report /opt/kodi."
    fi

    # Remove build trees and the build-only -dev packages.
    sudo rm -rf Arkbuild/home/ark/kodi
    sudo rm -rf Arkbuild/home/ark/kodi_dl_cache Arkbuild/home/ark/preseed_addon_dl.sh
    while read KODI_NEEDED_DEV_PACKAGE; do
      if [[ ! "$KODI_NEEDED_DEV_PACKAGE" =~ ^# ]] && [[ "$KODI_NEEDED_DEV_PACKAGE" == *"-dev"* ]]; then
        call_chroot "apt remove -y $KODI_NEEDED_DEV_PACKAGE"
      fi
    done <kodi_needed_dev_packages.txt
fi

# ---- Per-device userdata and launcher (both cache paths) ----
sudo cp -R kodi/userdata/ Arkbuild/opt/kodi/
sudo cp kodi/scripts/Kodi.sh Arkbuild/usr/local/bin/
sudo chmod 777 Arkbuild/usr/local/bin/Kodi.sh

# oga_controls translates the gamepad to keyboard input for Kodi navigation. It
# reads its key map from oga_controls_settings.txt relative to its working
# directory, which Kodi.sh sets to /opt/kodi. Without this file EVERY button
# defaults to KEY_RIGHTALT (see oga_controls main.c) and nothing navigates, so
# install the Kodi-nav key map there. (The device path is fixed separately in
# build_ogacontrols.sh, where the rg503 profile is repointed at play_joystick.)
sudo cp kodi/oga_controls_settings.txt Arkbuild/opt/kodi/

# RG52 Mini only: route hardware-decoded video through the GL renderer instead of
# a dedicated overlay plane, so it rides the same RGA GUI rotation. dArkOS ships
# videoplayer.useprimerenderer forced to 0 ("Direct To Plane"); set it to 1 ("EGL")
# so CRendererDRMPRIME falls through to drm_prime_gles (EGL-imports the frame into
# the GL scene). RG43H keeps 0 (zero-copy direct-to-plane video).
if [ "$UNIT" == "rg52mini" ]; then
  sudo sed -i 's#\(id="videoplayer.useprimerenderer" default="true">\)0<#\11<#' Arkbuild/opt/kodi/userdata/guisettings.xml
fi

if [[ "$UNIT" != *"503"* ]]; then
  sudo sed -i '/<res width\="1920" height\="1440" aspect\="4:3"/s//<res width\="1623" height\="1180" aspect\="4:3"/g' Arkbuild/opt/kodi/share/kodi/addons/skin.estuary/addon.xml
fi

call_chroot "chown -R ark:ark /opt/kodi/"
