#!/bin/bash
#
# Resume the 2026-09-29 build from build_deps.sh onward.
#
# Written for the 2026-09-29 build; RESUME_BUILD_DATE=MMDDYYYY resumes another
# one (used for 10052026).
#
# The build died at 3h40m: the background shell that owned its stdout was killed
# for system memory pressure, the pipe lost its reader, and the next write took
# make with it. WSL was then restarted, so every mount and loop device is gone -
# but both image files are intact, and with them the 3h16m of package installs.
#
# So this re-attaches and re-mounts what setup_partition and bootstrap_rootfs had
# mounted, then picks up at the core_builds copy and build_deps.sh. It never calls
# mkfs or parted: the partitions and filesystems already exist and formatting them
# is exactly the mistake this script is written to avoid.
#
# The step list in resume_body.sh is cut verbatim out of build_rg52mini.sh so it
# cannot drift. Of the variables the skipped steps used to set, the body reads
# exactly five - DISK, FILESYSTEM, LOOP_DEV, ROOT_FILESYSTEM_FORMAT and
# mountpoint - checked by walking every script the body sources. CHROOT_DIR is
# set by build_deps.sh itself.
#
# No set -e. prepare.sh and most build steps return non-zero harmlessly - the
# first version of this script had set -e and died inside prepare.sh, on
# "apt list --installed | grep -q <tool>" for a tool that was not installed,
# before any of the checks below could run.

cd /home/mamaich/rg52/dArkOS_rg52mini || exit 1

export CHIPSET=rk3562
export UNIT=rg52mini
export UNIT_DTB=${CHIPSET}-${UNIT}
export ENABLE_CACHE=y
CORE_BUILDS_SYMLINK_NEEDED=y
export BSP_PATH="${PWD}/BSP"
export BUILD_ARMHF=y
export BUILD_BLUEALSA=${BUILD_BLUEALSA:-y}
export BUILD_RKMPP_FFMPEG=${BUILD_RKMPP_FFMPEG:-y}
export BUILD_KODI=${BUILD_KODI:-y}
export DEBIAN_CODE_NAME=trixie

# State the skipped steps would have set. Pinned, not recomputed: utils.sh
# derives BUILD_DATE from today, which would name a second image rather than
# finish this one.
export BUILD_DATE=${RESUME_BUILD_DATE:-09292026}
ROOT_FILESYSTEM_FORMAT="btrfs"
ROOT_FILESYSTEM_MOUNT_OPTIONS="defaults,noatime,compress=zstd:1"
SECTOR_SIZE=512
DARKOS_VERSION=${DARKOS_VERSION:-$(cat VERSION 2>/dev/null)}
if [ -n "$DARKOS_VERSION" ]; then
  DISK="dArkOS_${UNIT}_${DARKOS_VERSION}.img"
else
  DISK="dArkOS_${UNIT}_${DEBIAN_CODE_NAME}_${BUILD_DATE}.img"
fi
FILESYSTEM="ArkOS_File_System.img"
mountpoint=mnt/boot

die() { echo "ОТКАЗ: $*"; exit 1; }

[ -f "$DISK" ]       || die "нет образа $DISK"
[ -f "$FILESYSTEM" ] || die "нет rootfs $FILESYSTEM"
pgrep -f 'build_rg52mini.sh|resume_body.sh' >/dev/null && die "сборка уже идёт"

# The arm64 chroot needs qemu through binfmt; a WSL restart can lose it.
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || die "binfmt qemu-aarch64 не зарегистрирован"

echo "=== перемонтирование ==="
LOOP_DEV=$(losetup -j "$DISK" | cut -d: -f1 | head -1)
if [ -z "$LOOP_DEV" ]; then
  LOOP_DEV=$(sudo losetup --show -Pf "$DISK") || die "losetup не смог привязать $DISK"
  sudo partprobe "$LOOP_DEV" 2>/dev/null
  sleep 1
fi
echo "  loop: $LOOP_DEV"
[ -b "${LOOP_DEV}p3" ] || die "нет раздела ${LOOP_DEV}p3"
[ -b "${LOOP_DEV}p4" ] || die "нет раздела ${LOOP_DEV}p4"

mkdir -p Arkbuild "$mountpoint" Arkbuild_ccache

if ! grep -qs " $PWD/Arkbuild " /proc/mounts; then
  sudo mount -t "$ROOT_FILESYSTEM_FORMAT" -o "${ROOT_FILESYSTEM_MOUNT_OPTIONS},loop" \
       "$FILESYSTEM" Arkbuild/ || die "не смонтировался $FILESYSTEM"
  echo "  Arkbuild смонтирован"
else
  echo "  Arkbuild уже смонтирован"
fi

# What is inside had better be the rootfs this build left behind, not an empty
# filesystem. If it is empty, something other than a restart happened.
PKGS=$(sudo chroot Arkbuild dpkg -l 2>/dev/null | grep -c '^ii')
echo "  пакетов в chroot: $PKGS"
[ "$PKGS" -gt 1000 ] || die "в chroot только $PKGS пакетов - это не то состояние, которое ожидалось"
[ -d Arkbuild/home/ark ] || die "нет Arkbuild/home/ark"

for m in dev dev/pts proc sys; do
  grep -qs " $PWD/Arkbuild/$m " /proc/mounts && { echo "  Arkbuild/$m уже смонтирован"; continue; }
  case "$m" in
    dev/pts) sudo mount -t devpts none Arkbuild/dev/pts -o newinstance,ptmxmode=0666 ;;
    *)       sudo mount --bind "/$m" "Arkbuild/$m" ;;
  esac || die "не смонтировался Arkbuild/$m"
  echo "  Arkbuild/$m смонтирован"
done

if ! grep -qs " $PWD/$mountpoint " /proc/mounts; then
  sudo mount "${LOOP_DEV}p3" "$mountpoint" || die "не смонтировался ${LOOP_DEV}p3"
  echo "  $mountpoint смонтирован"
else
  echo "  $mountpoint уже смонтирован"
fi
[ -f "$mountpoint/Image" ] || die "на загрузочном разделе нет Image"
echo "  Image на месте: $(stat -c%s "$mountpoint/Image") байт"
echo "  модулей в rootfs: $(sudo find Arkbuild/lib/modules -name '*.ko' 2>/dev/null | wc -l)"

source ./utils.sh
export BUILD_DATE=${RESUME_BUILD_DATE:-09292026}   # utils.sh overwrites it
source ./prepare.sh

echo "=== продолжаю сборку: $DISK на $LOOP_DEV ==="
date '+начало: %H:%M:%S %d.%m.%Y'

(
source ./resume_body.sh
) 2>&1 | tee -a build.log

echo "RG52 Mini build completed. Final image is ready."
