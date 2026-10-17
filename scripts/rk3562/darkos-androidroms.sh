#!/bin/sh
# darkos-androidroms - ROMs from the Android storage on a dual-boot card.
#
# On the combined "dArkOS + GammaOS" SD card there is no ROMS partition: the
# games live in Android's shared storage, /storage/emulated/0/ROMs, which on
# disk is media/0/ROMs inside the userdata partition (ext4 with casefold). This
# mounts userdata (by its GPT partition label, on the card dArkOS runs from)
# at /mnt/androiddata and binds
# the ROMs folder to /roms and its tools folder to /opt/system/Tools, before
# EmulationStation starts. /boot/dualboot marks such a card; without it this
# does nothing.
#
# Access: Android keeps media/0 setgid to group 1023 (media_rw) with a default
# ACL giving that group rwx, so ark only needs to be in a group with gid 1023.
# What ark creates there gets group 1023 and group rw by itself, and Android
# reads and writes it. Avoid chmod without group bits there: it narrows the
# ACL mask and takes Android's write access away.
#
# Until Android has started once, userdata is not formatted: then /roms stays
# an empty local folder, the boot goes on, and the next boot picks it up.

MNT=/mnt/androiddata
log() { echo "darkos-androidroms: $*"; }

[ -f /boot/dualboot ] || exit 0

getent group media_rw > /dev/null 2>&1 || groupadd -g 1023 media_rw
id -nG ark | grep -qw media_rw || usermod -aG media_rw ark

mountpoint -q /roms && exit 0

# userdata on the card dArkOS runs from - not by /dev/disk/by-partlabel,
# which may well point at the Android userdata in the internal eMMC
ROOTDISK=/dev/$(lsblk -n -o PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null)
DEV=""
i=0
while [ -z "$DEV" ] && [ $i -lt 10 ]; do
    DEV=$(lsblk -lnp -o NAME,PARTLABEL "$ROOTDISK" 2>/dev/null | awk '$2 == "userdata" {print $1; exit}')
    [ -n "$DEV" ] || { sleep 1; i=$((i + 1)); }
done
if [ -z "$DEV" ]; then
    log "no partition labelled userdata on $ROOTDISK"
    exit 0
fi
TYPE=$(blkid -o value -s TYPE "$DEV" 2>/dev/null)
if [ "$TYPE" != ext4 ]; then
    log "userdata is not ext4 yet (${TYPE:-unformatted}): start the Android system once"
    exit 0
fi
mkdir -p "$MNT"
if ! mountpoint -q "$MNT" && ! mount -t ext4 -o rw,noatime "$DEV" "$MNT"; then
    log "userdata does not mount"
    exit 0
fi
if [ ! -d "$MNT/media/0" ]; then
    log "no media/0 on userdata yet: start the Android system once"
    umount "$MNT"
    exit 0
fi
# GammaOS's setup wizard lays out ROMs itself: it unpacks its own archive over
# the folder and deletes every *state.auto and *state.auto.png in it, so
# nothing written there before it has run would survive. It leaves
# setupcompleted at the top of userdata (/data/setupcompleted) when done.
if [ ! -e "$MNT/setupcompleted" ]; then
    log "GammaOS setup has not been completed yet: finish it in GammaOS first"
    umount "$MNT"
    exit 0
fi

R="$MNT/media/0/ROMs"
[ -d "$R" ] || sudo -u ark mkdir "$R"
mount --bind "$R" /roms || { log "cannot bind $R"; exit 0; }
log "/roms is $R"

# The first time: the folder structure the image ships (/roms.tar) and the
# themes (/tempthemes), without overwriting anything already there. Copied as
# ark with umask 007, so that every new directory and file keeps the group
# 1023 rw (rwx) the default ACL gives.
if [ ! -f /roms/.darkos ]; then
    log "laying out the ROMs folder"
    T=$(mktemp -d)
    chmod 755 "$T"   # cp below runs as ark
    if [ -f /roms.tar ] && tar -C "$T" -xf /roms.tar; then
        sudo -u ark sh -c "umask 007; cp -rn --no-preserve=mode,ownership,timestamps '$T/roms/.' /roms/"
    fi
    rm -rf "$T"
    if [ -d /tempthemes ]; then
        sudo -u ark sh -c "umask 007; mkdir -p /roms/themes; cp -rn --no-preserve=mode,ownership,timestamps /tempthemes/. /roms/themes/" &&
            rm -rf /tempthemes
    fi
    sudo -u ark touch /roms/.darkos
fi

# Files that came in through Android have no execute bit, which the PortMaster
# tools need. Only those lacking it; u+x,g+x keeps the group bits. Ports get
# theirs from runport.sh, when a new one is started.
[ -d /roms/tools ] && find /roms/tools -type f ! -perm -u=x -exec chmod u+x,g+x {} + 2>/dev/null

mkdir -p /opt/system/Tools
if [ -d /roms/tools ] && ! mountpoint -q /opt/system/Tools; then
    mount --bind /roms/tools /opt/system/Tools
fi
exit 0
