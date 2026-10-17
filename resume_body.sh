
# Copy rk3562_core_builds submodule into chroot
# This is the bmdhacks fork of rk3566_core_builds.
# RK3562 and RK3566 are binary compatible — pre-built emulators work on both.
if [[ "${CORE_BUILDS_SYMLINK_NEEDED}" == "y" ]]; then
  echo "Copying rk3562_core_builds into chroot..."
  sudo mkdir -p Arkbuild/home/ark
  if [ ! -d "Arkbuild/home/ark/rk3562_core_builds" ]; then
    sudo cp -a rk3562_core_builds Arkbuild/home/ark/rk3562_core_builds
  fi
  sudo chown -R 1000:1000 Arkbuild/home/ark/rk3562_core_builds
fi

source ./build_deps.sh
source ./build_sdl2.sh
source ./build_sdl3shim.sh
source ./build_ppssppsa.sh
source ./build_ppsspp-2021sa.sh
source ./build_duckstationsa.sh
source ./build_pcsx2sa.sh
source ./build_mupen64plussa.sh
source ./build_gzdoom.sh
source ./build_lzdoom.sh
source ./build_retroarch.sh
source ./build_retrorun.sh
source ./build_yabasanshirosa.sh
source ./build_mednafen.sh
source ./build_ecwolfsa.sh
source ./build_hypseus-singe.sh
source ./build_openbor.sh
source ./build_solarus.sh
source ./build_scummvmsa.sh
source ./build_fake08.sh
source ./build_xroar.sh
source ./build_mvem.sh
source ./build_bigpemu.sh
source ./build_ogage.sh
source ./build_ogacontrols.sh
source ./build_351files.sh
source ./build_filemanager.sh
source ./build_filebrowser.sh
source ./build_gptokeyb.sh
source ./build_drmtool.sh
source ./build_image-viewer.sh
source ./build_emulationstation-rk3562.sh
source ./build_linapple.sh
source ./build_applewinsa.sh
source ./build_piemu.sh
source ./build_ti99sim.sh
source ./build_gametank.sh
source ./build_openmsxsa.sh
source ./build_flycastsa.sh
source ./build_dolphinsa.sh
source ./build_sdljoytest.sh
source ./build_controllertester.sh
source ./build_drastic.sh
source ./build_dsperate.sh
source ./build_vkrotate.sh
source ./build_gl4esfix.sh
if [[ "${BUILD_RKMPP_FFMPEG}" == "y" ]]; then
  source ./build_ffmpeg.sh
fi
if [[ "${BUILD_KODI}" == "y" ]]; then
  source ./build_kodi.sh
fi
if [[ "${BUILD_BLUEALSA}" == "y" ]]; then
  source ./build_bluealsa.sh
fi
source ./finishing_touches-rk3562.sh
source ./cleanup_filesystem.sh
source ./write_rootfs-rk3562.sh
source ./clean_mounts.sh
source ./create_image.sh
