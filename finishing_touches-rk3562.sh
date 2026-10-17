#!/bin/bash
#
# Finishing touches for RK3562 (RG52 Mini)
#
# Hardware specifics:
# - SoC: Rockchip RK3562 (quad Cortex-A53)
# - GPU: Mali Bifrost G52, DDK g29p1 64-bit (BSP, system-wide incl ES); g13p0 32-bit
# - Display: 720x1280 MIPI DSI panel (portrait orientation)
# - Audio: RK817 codec + RK628 HDMI bridge
# - Input: play_joystick driver (custom gamepad), adc-keys, rk805 pwrkey
# - PMIC: RK817 (battery, charger, codec integrated)
#

# Create extlinux.conf for boot
sudo mkdir -p ${mountpoint}/extlinux
# Build kernel command line — portrait-panel devices need fbcon rotation
# console=tty1 is gone on purpose. With it, every kernel message is printed
# onto the panel, straight over the boot logo. Messages now go only to the
# serial port, which is where anyone debugging this will be looking anyway.
#
# loglevel is 5 rather than 0 because fbcon refuses to draw the logo at all
# when console_loglevel <= CONSOLE_LOGLEVEL_QUIET, which is 4:
#   fbcon.c: if (logo_shown < 0 && console_loglevel <= CONSOLE_LOGLEVEL_QUIET)
#                logo_shown = FBCON_LOGO_DONTSHOW;
# Nothing extra reaches the screen from raising it, since the panel is no
# longer a console.
#
# vt.global_cursor_default=0 hides the blinking cursor the logo would
# otherwise sit behind (rg43h already carries this on rk3566).
KCMD_BASE="root=/dev/mmcblk1p4 rootfstype=btrfs initrd=/uInitrd rootwait rw fsck.repair=yes quiet splash net.ifnames=0 console=ttyFIQ0,1500000 plymouth.ignore-serial-consoles consoleblank=0 vt.global_cursor_default=0 loglevel=5"
if [ "$UNIT" == "rg52mini" ]; then
  KCMD_VIDEO="video=HDMI-A-1:1280x720@60 fbcon=rotate:1"
else
  KCMD_VIDEO=""
fi
cat <<EOF | sudo tee ${mountpoint}/extlinux/extlinux.conf
LABEL dArkOS
  LINUX /Image
  FDT /${UNIT_DTB}.dtb
  APPEND ${KCMD_BASE} ${KCMD_VIDEO}
EOF

# Copy optional files if present
if [ -d "optional" ]; then
  if [ ! -z "$(find optional/ -mindepth 1 -maxdepth 1)" ]; then
    sudo cp optional/* ${mountpoint}/
  fi
fi

# Tell systemd to ignore PowerKey presses - let the Global Hotkey daemon handle that
echo "HandlePowerKey=ignore" | sudo tee -a Arkbuild/etc/systemd/logind.conf

# Add important exports to .bashrc for user ark
echo "export PATH=\"\$PATH:/usr/sbin\"" | sudo tee -a Arkbuild/home/ark/.bashrc
sudo chroot Arkbuild/ bash -c "chown ark:ark /home/ark/.bashrc"

# Set the hostname
NAME="${UNIT}"
echo "$NAME" | sudo tee Arkbuild/etc/hostname
echo -e "# This host address\n127.0.1.1\t${NAME}" | sudo tee -a Arkbuild/etc/hosts

# Copy the necessary .asoundrc file for RK817 audio codec
sudo cp audio/.asoundrc.${CHIPSET} Arkbuild/home/ark/.asoundrc
sudo cp audio/.asoundrcbak.${CHIPSET} Arkbuild/home/ark/.asoundrcbak
sudo cp audio/.asoundrcbt.${CHIPSET} Arkbuild/home/ark/.asoundrcbt
# HDMI audio hot-switch: routes default ALSA PCM to the RK628 HDMI bridge
# (rockchiphdmirk628 ALSA card) when an HDMI display is connected.
sudo cp audio/.asoundrchdmi Arkbuild/home/ark/.asoundrchdmi
sudo cp audio/audio-switch.sh Arkbuild/usr/local/bin/audio-switch.sh
sudo chmod +x Arkbuild/usr/local/bin/audio-switch.sh
sudo cp audio/99-hdmi-audio.rules Arkbuild/etc/udev/rules.d/99-hdmi-audio.rules
sudo chroot Arkbuild/ bash -c "chown ark:ark /home/ark/.asoundrc*"
sudo chroot Arkbuild/ bash -c "ln -sfv /home/ark/.asoundrc /etc/asound.conf"
sudo chroot Arkbuild/ bash -c "cp -fv /usr/share/alsa/alsa.conf /usr/share/alsa/alsa.conf.mednafen"
sudo chroot Arkbuild/ bash -c "sed -i '/\"\~\/.asoundrc\"/s//\"\~\/.asoundrc.mednafen\"/' /usr/share/alsa/alsa.conf.mednafen"

# Bluetooth for RK3562 — USB dongle only (RK915 has no BT)
# Generic enable_bluetooth.sh runs rtk_hciattach on UART (for RK3566 Realtek combo chips).
# Replace with RK3562 version that just starts bluez + bluealsa services.
if [[ "${BUILD_BLUEALSA}" == "y" ]]; then
  # Replace generic enable_bluetooth.sh with RK3562 version
  sudo cp scripts/rk3562/enable_bluetooth.sh Arkbuild/usr/local/bin/enable_bluetooth.sh
  sudo cp scripts/rk3562/bttoggle.sh Arkbuild/usr/local/bin/bttoggle.sh
  sudo cp scripts/rk3562/btconnected.sh Arkbuild/usr/local/bin/btconnected.sh
  sudo chmod 755 Arkbuild/usr/local/bin/{enable_bluetooth,bttoggle,btconnected}.sh

  # Override service type — RK3562 script exits immediately (no foreground rtk_hciattach)
  sudo mkdir -p Arkbuild/etc/systemd/system/enable_bluetooth.service.d/
  cat <<'EOF' | sudo tee Arkbuild/etc/systemd/system/enable_bluetooth.service.d/rk3562.conf
[Service]
Type=oneshot
Restart=no
RemainAfterExit=yes
EOF

  # Enable bluetooth by default — bluez handles USB dongle hotplug via btusb.
  # bluealsa only if it is actually there: enabling a unit whose binary is
  # missing gives a device that prints "Failed to start bluealsa.service" on
  # every boot and offers no clue why. That happened once already, when Kodi's
  # dependency resolution removed libasound2-dev and bluez-alsa then failed to
  # configure - the build carried on regardless and the service was enabled.
  # BlueZ refuses HID from a device it does not consider bonded, and has done
  # by default since 5.6x (ClassicBondedOnly, true unless told otherwise).
  # Plenty of Bluetooth gamepads pair the old way and never bond, so they pair
  # happily, show up as Connected, and then produce no input device at all -
  # the only sign is one line in the daemon log:
  #
  #   profiles/input/device.c:hidp_add_connection()
  #   Rejected connection from !bonded device /org/bluez/hci0/dev_XX_XX_...
  #
  # The trade is real: an unbonded HID link can be spoofed, and a spoofed HID
  # link is keystrokes. On a handheld that stores no credentials and whose
  # alternative is "gamepads do not work", it is the right way round.
  if [ -f Arkbuild/etc/bluetooth/input.conf ]; then
    if ! grep -q '^ClassicBondedOnly' Arkbuild/etc/bluetooth/input.conf; then
      sudo sed -i 's/^\[General\]/[General]\nClassicBondedOnly=false/' \
        Arkbuild/etc/bluetooth/input.conf
    fi
  fi

  # bluez-alsa 4.x renamed the daemon to bluealsad (and bluealsa-cli to
  # bluealsactl), so test for both: the old name for anything older, the new
  # one for what we build today. Testing only the old name is how a working
  # build was reported as missing.
  if sudo test -x Arkbuild/usr/bin/bluealsad || sudo test -x Arkbuild/usr/bin/bluealsa; then
    call_chroot "systemctl enable bluetooth bluealsa enable_bluetooth"
  else
    echo "WARNING: the bluealsa daemon is missing - enabling bluetooth without it."
    echo "         Bluetooth input will work; Bluetooth audio will not."
    call_chroot "systemctl enable bluetooth enable_bluetooth"
  fi
fi

# Kernel modules are built with CONFIG_DEBUG_INFO=y, same as the vendor's
# EmuELEC config.  EmuELEC strips them while packing its squashfs; we have no
# such step, so the DWARF rides along into the image - 97% of every .ko.
# Measured on a trivial DVB driver: a8293.ko 359304 -> 9968 bytes.
# --strip-debug, never a plain strip: the symbol table carries the CRCs that
# CONFIG_MODVERSIONS=y checks at load time, and without it nothing loads -
# including aic8800, i.e. no wifi.
echo "Stripping debug info from kernel modules..."
MODSTRIP="$(ls ${PWD}/prebuilts/gcc/linux-x86/aarch64/*/bin/aarch64-linux-gnu-strip 2>/dev/null | head -1)"
if [ -z "${MODSTRIP}" ]; then
  MODSTRIP=/opt/toolchains/gcc-linaro-6.3.1-2017.05-x86_64_aarch64-linux-gnu/bin/aarch64-linux-gnu-strip
fi
if [ -x "${MODSTRIP}" ]; then
  echo "  modules before: $(sudo du -sh Arkbuild/lib/modules 2>/dev/null | cut -f1)"
  sudo find Arkbuild/lib/modules -name '*.ko' -exec "${MODSTRIP}" --strip-debug {} +
  echo "  modules after:  $(sudo du -sh Arkbuild/lib/modules 2>/dev/null | cut -f1)"
else
  echo "  WARNING: no aarch64 strip found, modules keep their debug info"
fi

# Second swap tier on the eMMC, behind zram.  The 256 MB GPT partition named
# "swap" is there on these devices but ships unformatted (filled with 0xcc),
# so it needs one mkswap before it is usable.  That is the one destructive
# step in this whole image, so it is fenced in:
#
#   - the partition is found by GPT label, never by a device path, so it
#     cannot drift onto mmcblk0p3 because someone repartitioned;
#   - blkid must report either nothing or an existing swap.  Any filesystem
#     down there and the script refuses and says so;
#   - the size has to look like the partition we expect;
#   - it must not be mounted.
#
# Priority 10, below zram's 100: zram takes everything it can compress and
# only what it cannot reaches the flash.  This matters for eMMC wear.
echo "Installing eMMC swap service..."
sudo tee Arkbuild/usr/local/sbin/emmc-swap > /dev/null <<'EMMCEOF'
#!/bin/sh
# Enable the eMMC swap partition as a second tier behind zram.
set -e
DEV=/dev/disk/by-partlabel/swap

# udev may not have laid out /dev/disk/by-partlabel yet. Wait, briefly, rather
# than exiting quietly and leaving swap off with nothing to show for it.
i=0
while [ ! -b "$DEV" ] && [ $i -lt 30 ]; do
    sleep 1
    i=$((i + 1))
done
if [ ! -b "$DEV" ]; then
    echo "emmc-swap: no partition labelled 'swap' after ${i}s, nothing to do" >&2
    exit 0
fi
REAL=$(readlink -f "$DEV")
grep -q "^$REAL " /proc/swaps && exit 0

# Never touch something that is mounted.
if grep -q "^$REAL " /proc/mounts; then
    echo "emmc-swap: $REAL is mounted, refusing" >&2
    exit 0
fi

# Never touch something that already holds a filesystem.
TYPE=$(blkid -o value -s TYPE "$REAL" 2>/dev/null || true)
case "$TYPE" in
    swap) swapon "$REAL" -p 10; exit 0 ;;
    "")   ;;   # raw, as shipped - safe to format
    *)    echo "emmc-swap: $REAL holds $TYPE, refusing to mkswap" >&2; exit 0 ;;
esac

# Sanity-check the size before formatting: 64 MB .. 2 GB.
SZ=$(blockdev --getsize64 "$REAL" 2>/dev/null || echo 0)
if [ "$SZ" -lt 67108864 ] || [ "$SZ" -gt 2147483648 ]; then
    echo "emmc-swap: $REAL is $SZ bytes, not the expected swap partition" >&2
    exit 0
fi

echo "emmc-swap: formatting $REAL ($SZ bytes) as swap"
mkswap -L rg52swap "$REAL" > /dev/null
swapon "$REAL" -p 10
EMMCEOF
sudo chmod 755 Arkbuild/usr/local/sbin/emmc-swap

sudo tee Arkbuild/etc/systemd/system/emmc-swap.service > /dev/null <<'EMMCUNITEOF'
[Unit]
Description=Swap on the eMMC swap partition (second tier, behind zram)
# No DefaultDependencies=no here: this one needs /dev/disk/by-partlabel, which
# only exists once udev has run, and the default ordering after sysinit.target
# is what guarantees that.
Wants=systemd-udev-settle.service
After=systemd-udev-settle.service local-fs.target zram-swap.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/emmc-swap
ExecStop=/bin/sh -c 'swapoff /dev/disk/by-partlabel/swap 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
EMMCUNITEOF

call_chroot "systemctl enable emmc-swap"

# Compressed swap in RAM.  The RG52 Mini has 2 GB, which Dolphin and PCSX2 can
# exhaust; swapping to compressed RAM is far cheaper than swapping to the eMMC,
# and costs nothing when unused.  Priority 100 deliberately outranks any
# on-disk swap (the rg43h fstab entry uses pri=10), so zram always fills first
# and the slow device only takes what zram could not compress.
echo "Installing zram swap..."
sudo tee Arkbuild/usr/local/sbin/zram-swap > /dev/null <<'ZRAMEOF'
#!/bin/sh
# Bring up /dev/zram0 as swap.  CONFIG_ZRAM=y, so the device already exists;
# modprobe is only a fallback for a modular kernel.
set -e
DEV=/dev/zram0
SIZE=1536M        # a ceiling, not a reservation: RAM is taken as pages arrive.
                  # Bigger means the eMMC tier below is reached later, which is
                  # the only real lever on how much gets written to flash.
# Preference order, first one the kernel offers wins. Writing a name that is
# not in comp_algorithm fails silently and leaves the default in place, so the
# list is walked against what the kernel actually reports.
#
# lzo-rle leads because speed is what matters here: four A53s are the scarce
# resource, and zram only earns its keep if compressing costs less than the
# fault it avoids. It has been the kernel's own default since 5.1 for the same
# reason. lz4 is next (the kernel now carries it, see CONFIG_CRYPTO_LZ4), then
# zstd, which compresses appreciably better and would push the eMMC tier
# further out of reach - move it to the front if RAM turns out to be tighter
# than CPU.
ALGO_PREF="lzo-rle lz4 zstd lzo"

[ -e "$DEV" ] || modprobe zram num_devices=1 2>/dev/null || true
[ -e "$DEV" ] || exit 0
grep -q "^$DEV " /proc/swaps && exit 0

swapoff "$DEV" 2>/dev/null || true
echo 1 > /sys/block/zram0/reset 2>/dev/null || true
AVAIL=$(tr -d "[]" < /sys/block/zram0/comp_algorithm 2>/dev/null)
ALGO=""
for a in $ALGO_PREF; do
    for have in $AVAIL; do
        if [ "$a" = "$have" ]; then ALGO="$a"; break 2; fi
    done
done
if [ -n "$ALGO" ]; then
    echo "$ALGO" > /sys/block/zram0/comp_algorithm
    echo "zram: compressing with $ALGO"
else
    echo "zram: none of '$ALGO_PREF' available ($AVAIL), keeping the default" >&2
fi
echo "$SIZE" > /sys/block/zram0/disksize
mkswap "$DEV" > /dev/null
swapon "$DEV" -p 100
ZRAMEOF
sudo chmod 755 Arkbuild/usr/local/sbin/zram-swap

sudo tee Arkbuild/etc/systemd/system/zram-swap.service > /dev/null <<'ZRAMUNITEOF'
[Unit]
Description=Compressed swap in RAM (zram)
DefaultDependencies=no
# Not After=local-fs.target: tmp.mount, like every tmpfs mount, is After
# swap.target, and local-fs.target After tmp.mount, so that made a cycle that
# systemd broke at boot by dropping either this job (no zram swap) or
# tmp.mount (no tmpfs /tmp), depending on the boot. The script needs only the
# root filesystem and /sys.
After=systemd-modules-load.service systemd-remount-fs.service
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zram-swap
ExecStop=/sbin/swapoff /dev/zram0

[Install]
WantedBy=multi-user.target
ZRAMUNITEOF

# Swapping into RAM is cheap, so lean on it harder than the default of 60.
sudo tee Arkbuild/etc/sysctl.d/99-zram.conf > /dev/null <<SYSCTLEOF
# Swapping into compressed RAM is cheap, so lean on it harder than the
# default of 60. The eMMC tier sits at priority 10 and only sees what zram
# could not take, so a high value here does not translate into flash writes.
vm.swappiness = 100

# One page per swap-in instead of eight. The default assumes a rotating disk
# where reading ahead is nearly free; with zram every extra page costs a
# decompression that is usually wasted.
vm.page-cluster = 0
SYSCTLEOF

call_chroot "systemctl enable zram-swap"

# Sleep script and set default SuspendState to freeze
sudo mkdir -p Arkbuild/usr/lib/systemd/system-sleep
sudo cp scripts/sleep.${CHIPSET} Arkbuild/usr/lib/systemd/system-sleep/sleep
sudo chmod 777 Arkbuild/usr/lib/systemd/system-sleep/sleep
sudo sed -i "/SuspendState\=/c\SuspendState\=freeze" Arkbuild/etc/systemd/sleep.conf

# Set DRM on boot
sudo chroot Arkbuild/ bash -c "(crontab -l 2>/dev/null; echo \"@reboot /usr/local/bin/hdmi-test.sh &\") | crontab -"

# Set performance governor to ondemand on boot
sudo chroot Arkbuild/ bash -c "(crontab -l 2>/dev/null; echo \"@reboot /usr/local/bin/perfnorm quiet &\") | crontab -"

# Copy necessary tools for expansion of ROOTFS and convert fat32 games partition to exfat on initial boot
sudo cp scripts/expandtoexfat.sh.${CHIPSET} ${mountpoint}/expandtoexfat.sh
sudo cp scripts/firstboot.sh ${mountpoint}/firstboot.sh
sudo cp scripts/firstboot.service Arkbuild/etc/systemd/system/firstboot.service
sudo chroot Arkbuild/ bash -c "systemctl enable firstboot"

# Add hotkeydaemon service and python script
sudo cp hotkeydaemon/killer_daemon.service Arkbuild/etc/systemd/system/killer_daemon.service
sudo cp hotkeydaemon/killer_daemon.py Arkbuild/usr/local/bin/killer_daemon.py
sudo chmod 777 Arkbuild/usr/local/bin/killer_daemon.py
sudo chroot Arkbuild/ bash -c "systemctl disable killer_daemon"

# Add amiga script
sudo cp amiga/amiga.sh Arkbuild/usr/local/bin/

# Generate fstab to be used after EASYROMS expansion
if [ "$ROOT_FILESYSTEM_FORMAT" == "btrfs" ]; then
  ROOT_FILESYSTEM_MOUNT_OPTIONS="${ROOT_FILESYSTEM_MOUNT_OPTIONS},ssd_spread"
fi
SWAP_LINE=""
if [ "$UNIT" == "rg43h" ]; then
  SWAP_LINE="
PARTLABEL=swap none swap sw,pri=10 0 0"
fi
cat <<EOF | sudo tee ${mountpoint}/fstab.exfat
/dev/mmcblk1p4  /  ${ROOT_FILESYSTEM_FORMAT} ${ROOT_FILESYSTEM_MOUNT_OPTIONS} 0 0

/dev/mmcblk1p3 /boot vfat defaults,noatime 0 0
/dev/mmcblk1p5 /roms exfat defaults,auto,umask=000,uid=1000,gid=1000,noatime 0 0
/roms/tools /opt/system/Tools none nofail,x-systemd.device-timeout=7,bind${SWAP_LINE}
EOF

# The same for a dual-boot "dArkOS + GammaOS" card, where partition 5 is
# GammaOS's boot FAT and the ROMs come from the Android storage instead
# (darkos-androidroms.service mounts them and binds /opt/system/Tools).
cat <<EOF | sudo tee ${mountpoint}/fstab.dualboot
/dev/mmcblk1p4  /  ${ROOT_FILESYSTEM_FORMAT} ${ROOT_FILESYSTEM_MOUNT_OPTIONS} 0 0

/dev/mmcblk1p3 /boot vfat defaults,noatime 0 0${SWAP_LINE}
EOF

# Dual-boot card: ROMs from Android's userdata. Does nothing without
# /boot/dualboot, which the combined image's builder puts there.
sudo install -m 755 scripts/rk3562/darkos-androidroms.sh Arkbuild/usr/local/sbin/darkos-androidroms
sudo install -m 644 scripts/rk3562/darkos-androidroms.service Arkbuild/etc/systemd/system/darkos-androidroms.service
sudo chroot Arkbuild/ bash -c "systemctl enable darkos-androidroms"

# Disable getty on tty0 and tty1
sudo chroot Arkbuild/ bash -c "systemctl disable getty@tty0.service getty@tty1.service"

# Disable some other unneeded services
sudo chroot Arkbuild/ bash -c "systemctl disable ModemManager polkit"

# Disable ssh service from automatically starting
sudo chroot Arkbuild/ bash -c "systemctl disable ssh"

# Update Message of the Day
sudo cp -f scripts/00-header Arkbuild/etc/update-motd.d/00-header
sudo cp -f scripts/10-help-text Arkbuild/etc/update-motd.d/10-help-text
sudo rm -f Arkbuild/etc/motd
sudo chmod 777 Arkbuild/etc/update-motd.d/*

# RG43H Pro: low swappiness for eMMC swap (only swap under real memory pressure)
if [ "$UNIT" == "rg43h" ]; then
  echo "vm.swappiness=10" | sudo tee Arkbuild/etc/sysctl.d/99-swap.conf
fi

# Load the WiFi kernel driver matching this device's hardware revision.
# There are two RG52 Mini hardware revisions with different WiFi chips:
#   rev A: RK915 (Microchip WILC1000) — SDIO vendor 0x0296
#   rev B: AIC8800DL (Aicsemi)         — SDIO vendor 0xc8a1
# RG43H/V Pro are RK915-only. Both drivers share the same wireless-wlan
# DT node and rockchip_wifi_power() GPIO helper, so there is no per-rev
# DT change.
#
# Loading both unconditionally doesn't work: each driver pulses
# rockchip_wifi_power() at module init, so whichever loads second stomps
# the first. wifi-driver-load.service tries rk915 first and falls back
# to aic8800 if rk915 can't find its chip; both drivers clean up the
# rail on failure so the fallback is safe.
sudo cp scripts/wifi-driver-load.sh Arkbuild/usr/local/bin/wifi-driver-load.sh
sudo chmod 755 Arkbuild/usr/local/bin/wifi-driver-load.sh
sudo cp scripts/wifi-driver-load.service Arkbuild/etc/systemd/system/wifi-driver-load.service
sudo chroot Arkbuild/ bash -c "systemctl enable wifi-driver-load"

# Import wifikeyfile.txt from the Tools folder at boot (upstream wifi_importer,
# reordered so it never holds EmulationStation back - see the unit).
sudo install -m 644 scripts/rk3562/wifi_importer.service Arkbuild/etc/systemd/system/wifi_importer.service
sudo chroot Arkbuild/ bash -c "systemctl enable wifi_importer"

# Revision A workaround: the panel stays black after the kernel takes over the
# display. panel-kick re-initialises the display before EmulationStation starts
# and exits at once on revision B. See docs/KNOWN-ISSUES.md.
# NGP45HT: not installed. It has no revision-A blank-panel bug, and panel-kick's
# is_rev_a() test (no husb311 on i2c) is true of every device without a Type-C
# controller, so on NGP45HT it would blank and restore the display for nothing.
if [ "$UNIT" == "rg52mini" ]; then
  sudo install -m 755 scripts/rk3562/panel-kick.sh Arkbuild/usr/local/bin/panel-kick.sh
  sudo install -m 644 scripts/rk3562/panel-kick.service Arkbuild/etc/systemd/system/panel-kick.service
  sudo chroot Arkbuild/ bash -c "systemctl enable panel-kick"
fi

# PortMaster does not know this joystick, so its get_controls() exports the
# whole gamecontrollerdb.txt (~470 KB) as SDL_GAMECONTROLLERCONFIG, past the
# kernel's 128 KB limit, and every port fails with "Argument list too long".
# portmaster-e2big appends PortMaster's own EmuELEC guard to mod_dArkOS.txt,
# at boot and again whenever a PortMaster update rewrites it.
sudo install -m 755 scripts/rk3562/portmaster-e2big.sh Arkbuild/usr/local/bin/portmaster-e2big.sh
sudo install -m 644 scripts/rk3562/portmaster-e2big.service Arkbuild/etc/systemd/system/portmaster-e2big.service
sudo install -m 644 scripts/rk3562/portmaster-e2big.path Arkbuild/etc/systemd/system/portmaster-e2big.path
sudo chroot Arkbuild/ bash -c "systemctl enable portmaster-e2big.service portmaster-e2big.path"

# Block udev SDIO-vendor auto-modprobe of aic8800 -- it races the rk915
# retry loop's rockchip_wifi_power() cycles and stomps aic8800's firmware
# download. wifi-driver-load.sh loads aic8800 explicitly when needed.
sudo install -m 644 scripts/rk3562/modprobe.d/dArkOS-wifi.conf \
    Arkbuild/etc/modprobe.d/dArkOS-wifi.conf

# Disable some unneeded interfaces in NetworkManager
cat <<EOF | sudo tee -a Arkbuild/etc/NetworkManager/NetworkManager.conf

[device]
wifi.scan-rand-mac-address=no

[keyfile]
unmanaged-devices=interface-name:p2p0;interface-name:ap0
EOF

# Remove requirement of sudo for controlling nmcli
cat <<EOF | sudo tee -a Arkbuild/etc/polkit-1/rules.d/10-networkmanager.rules
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager") == 0 &&
        subject.isInGroup("netdev")) {
        return polkit.Result.YES;
    }
});
EOF

# Default set timezone to New York
sudo chroot Arkbuild/ bash -c "ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime"

# Fetch older Debian library versions for PortMaster compatibility
source ./fetch_compat_libs.sh

# Various tools available through Options added here
sudo mkdir -p Arkbuild/opt/system/Advanced
sudo cp dArkOS_Tools/*.sh Arkbuild/opt/system/
# Scripts in dArkOS_Tools/rk3562/ are device-specific -- installed explicitly
# below rather than via a wildcard so each script only lands on the device(s)
# whose hardware can use it.
if [ -f "dArkOS_Tools/${CHIPSET}/Enable Low Battery Warning.sh" ]; then
  sudo cp "dArkOS_Tools/${CHIPSET}/Enable Low Battery Warning.sh" Arkbuild/opt/system/Advanced/
  sudo cp "dArkOS_Tools/${CHIPSET}/Enable Low Battery Warning.sh" Arkbuild/usr/local/bin/
fi
if [ -f "dArkOS_Tools/${CHIPSET}/Disable Low Battery Warning.sh" ]; then
  sudo cp "dArkOS_Tools/${CHIPSET}/Disable Low Battery Warning.sh" Arkbuild/opt/system/Advanced/
  sudo cp "dArkOS_Tools/${CHIPSET}/Disable Low Battery Warning.sh" Arkbuild/usr/local/bin/
fi
# Button swap scripts (RG52 Mini only -- has both HOME/FN and BACK buttons)
if [ "$UNIT" == "rg52mini" ]; then
  sudo cp "dArkOS_Tools/rk3562/Swap Start+Select with FN+Back.sh" Arkbuild/opt/system/Advanced/
  sudo cp "dArkOS_Tools/rk3562/Swap Start+Select with FN+Back.sh" Arkbuild/usr/local/bin/
  sudo cp "dArkOS_Tools/rk3562/Restore Start+Select.sh" Arkbuild/usr/local/bin/
fi
# Fan toggle scripts (RG52 Mini only -- RG43H Pro chassis has no fan)
if [ "$UNIT" == "rg52mini" ]; then
  sudo cp "dArkOS_Tools/rk3562/Disable Fan.sh" Arkbuild/opt/system/Advanced/
  sudo cp "dArkOS_Tools/rk3562/Disable Fan.sh" Arkbuild/usr/local/bin/
  sudo cp "dArkOS_Tools/rk3562/Enable Fan.sh" Arkbuild/usr/local/bin/
  sudo install -m 755 scripts/rk3562/fan-state-apply.sh \
      Arkbuild/usr/local/bin/fan-state-apply.sh
  sudo install -m 644 scripts/rk3562/fan-state.service \
      Arkbuild/etc/systemd/system/fan-state.service
  sudo chroot Arkbuild/ bash -c "systemctl enable fan-state"
fi
# Left stick inversion toggle (RG43H Pro / RG43V Pro -- shared DTB enables
# inversion to match RG43H wiring; RG43V Pro left stick is wired opposite and
# needs the inversion disabled at runtime).
if [ "$UNIT" == "rg43h" ] || [ "$UNIT" == "rg43v" ]; then
  sudo cp "dArkOS_Tools/rk3562/Left Stick Invert Toggle.sh" Arkbuild/opt/system/Advanced/
fi
# Stick-RGB LED control (all RK3562 devices). Backend tool talks to the LED
# MCU on /dev/ttyS1; led-state.service re-applies the saved colour at boot;
# "LED Settings" is a dialog config program in the Options menu. Lighting is
# OFF by default -- the service is a no-op until the user creates a config.
sudo install -m 755 scripts/rk3562/ledctl.sh Arkbuild/usr/local/bin/ledctl
sudo install -m 644 scripts/rk3562/led-state.service \
    Arkbuild/etc/systemd/system/led-state.service
sudo chroot Arkbuild/ bash -c "systemctl enable led-state"
sudo cp "dArkOS_Tools/rk3562/LED Settings.sh" Arkbuild/opt/system/
sudo cp dArkOS_Tools/Advanced/*.sh Arkbuild/opt/system/Advanced/
sudo cp scripts/"Enable Quick Mode".sh Arkbuild/opt/system/Advanced/
if [ -f "scripts/${CHIPSET}/Fix Audio.sh" ]; then
  sudo cp scripts/${CHIPSET}/"Fix Audio".sh Arkbuild/opt/system/Advanced/
fi
sudo cp scripts/"Switch to SD2 for Roms.sh" Arkbuild/opt/system/Advanced/
sudo chroot Arkbuild/ bash -c "chown -R ark:ark /opt"
sudo chmod -R 777 Arkbuild/opt/system/

# Copy performance scripts
sudo cp scripts/perf* Arkbuild/usr/local/bin/

# Ports: PortMaster ports as ark, scripts written for root-only systems as
# root (see the script)
sudo install -m 755 scripts/rk3562/runport.sh Arkbuild/usr/local/bin/runport.sh

# Over-the-air updates (docs/OTA.md): darkos-ota and Options -> Update in place
# of the generic Update.sh, which fetches upstream updates built for other
# chipsets
if [ "$UNIT" == "rg52mini" ] || [ "$UNIT" == "ngp45ht" ]; then
  sudo install -m 755 scripts/rk3562/darkos-ota Arkbuild/usr/local/sbin/darkos-ota
  sudo install -m 644 scripts/rk3562/darkos-ota-boot.service Arkbuild/etc/systemd/system/darkos-ota-boot.service
  sudo chroot Arkbuild/ bash -c "systemctl enable darkos-ota-boot"
  sudo install -m 755 dArkOS_Tools/rk3562/Update.sh Arkbuild/opt/system/Update.sh
fi

# NGP45HT: panel colour/temperature port (from ROCKNIX paneladj) and the CJK
# console font its Chinese dialog needs. Self-contained installer; on a card
# the same files ship as the ngp45ht-update package.
if [ "$UNIT" == "ngp45ht" ]; then
  bash ngp45ht/tools/ngp-panel/install.sh Arkbuild
  sudo chroot Arkbuild/ bash -c "systemctl enable ngp-panel-restore" || true
  # The eMMC tier of the swap setup is dead weight here: this device's eMMC
  # has no partition labelled "swap", so emmc-swap.service would start, wait
  # for /dev/disk/by-partlabel/swap, find nothing and exit - while dragging in
  # Wants=systemd-udev-settle.service (~1.9 s) for the privilege.  zram alone
  # covers the 2 GB of RAM.
  sudo chroot Arkbuild/ bash -c "systemctl disable emmc-swap" || true
fi

# Add preservation of SDL_VIDEO_EGL_DRIVER to sudoers
cat <<EOF | sudo tee Arkbuild/etc/sudoers.d/ark_preserve_sdl_video_egl_driver
Defaults        env_keep += "SDL_VIDEO_EGL_DRIVER"
EOF
sudo chmod 0440 Arkbuild/etc/sudoers.d/ark_preserve_sdl_video_egl_driver

# Add USB DAC Support
echo -e "Generating 20-usb-alsa.rules udev for usb dac support"
echo -e "KERNEL==\"controlC[0-9]*\", DRIVERS==\"usb\", SYMLINK=\"snd/controlC7\"" | sudo tee Arkbuild/etc/udev/rules.d/20-usb-alsa.rules
sudo chroot Arkbuild/ bash -c "(crontab -l 2>/dev/null; echo \"@reboot /usr/local/bin/checknswitchforusbdac.sh > /dev/null 2>&1 &\") | crontab -"

# DMA heap permissions — Mali EGL needs access as non-root user
echo -e "Generating 99-dma-heap.rules udev for Mali GPU access"
echo 'SUBSYSTEM=="dma_heap", MODE="0666"' | sudo tee Arkbuild/etc/udev/rules.d/99-dma-heap.rules

# The GPU's 1000 MHz step is the overclock one (perfoc, the "overclock"
# governor in ES), but devfreq has no turbo flag and allows its top step from
# the start: cap it at 900 MHz as soon as the device appears, so that a chip
# that does not take 1000 MHz is never sent there outside that mode, not even
# under the boot animation. The CPU's 2208 MHz step is turbo-mode and stays
# off until perfoc turns boost on.
echo 'ACTION=="add", SUBSYSTEM=="devfreq", KERNEL=="*.gpu", ATTR{max_freq}="900000000"' | sudo tee Arkbuild/etc/udev/rules.d/99-gpu-oc-cap.rules

# The last brightness other than 0: what the power key puts back after the
# "black" screensaver of ES turned the backlight off (scripts/pause.sh,
# Emulationstation/scripts.rk3562).
echo 'SUBSYSTEM=="backlight", ACTION=="add|change", ATTR{brightness}!="0", RUN+="/bin/sh -c '\''echo $attr{brightness} > /run/darkos-brightness'\''"' | sudo tee Arkbuild/etc/udev/rules.d/99-darkos-brightness.rules

# Joystick button swap persistence -- restore swap state on boot if flag file exists
echo 'ACTION=="add", SUBSYSTEM=="platform", DRIVER=="rk3562-joystick", RUN+="/bin/sh -c '\''test -f /home/ark/.config/.SWAP_START_HOME && echo 1 > /sys%p/swap_start_home'\''"' | sudo tee Arkbuild/etc/udev/rules.d/99-joystick-swap.rules

# Left stick inversion override -- disable DT-default inversion on boot if flag file exists
echo 'ACTION=="add", SUBSYSTEM=="platform", DRIVER=="rk3562-joystick", RUN+="/bin/sh -c '\''test -f /home/ark/.config/.LEFT_STICK_NOT_INVERTED && echo 0 > /sys%p/left_stick_invert'\''"' | sudo tee Arkbuild/etc/udev/rules.d/99-joystick-invert.rules

# RK817 PMIC poweroff service — bypasses ATF's broken SYSTEM_OFF
# (ATF asserts SLPPIN with pmic-reset-func=0 → resets instead of powering off)
sudo cp scripts/rk3562-poweroff.sh Arkbuild/usr/local/bin/rk3562-poweroff.sh
sudo chmod 755 Arkbuild/usr/local/bin/rk3562-poweroff.sh
sudo cp scripts/rk3562-poweroff.service Arkbuild/etc/systemd/system/rk3562-poweroff.service
call_chroot "systemctl enable rk3562-poweroff"

# RG43H Pro: warm-white panel LUT in VOP2 hardware gamma table.
# The JC4505 panel module ships with a cool white point (~7500K+) and there
# are no per-channel R/G/B controls in the panel's init sequence we can
# touch. We compensate via the VOP2 hardware GAMMA_LUT — applied once at
# boot and re-applied on resume. Zero per-frame CPU cost since the LUT
# lives in the display controller silicon.
if [ "$UNIT" == "rg43h" ]; then
  sudo install -m 0755 -o root -g root scripts/apply_panel_lut.py \
    Arkbuild/usr/local/bin/apply-panel-lut
  sudo install -m 0755 -o root -g root scripts/make_panel_lut.py \
    Arkbuild/usr/local/bin/make-panel-lut
  sudo install -d -m 0755 -o root -g root Arkbuild/etc/panel-lut
  sudo install -m 0644 -o root -g root scripts/panel-lut.rg43h.lut \
    Arkbuild/etc/panel-lut/current.lut
  sudo install -m 0644 -o root -g root scripts/panel-lut.service \
    Arkbuild/etc/systemd/system/panel-lut.service
  call_chroot "systemctl enable panel-lut"
fi

# Vulkan ICD manifest + info utility
sudo mkdir -p Arkbuild/usr/share/vulkan/icd.d
sudo cp BSP/vulkan/rk_vk.json Arkbuild/usr/share/vulkan/icd.d/
sudo cp BSP/vulkan/vulkaninfo Arkbuild/usr/bin/
sudo chmod 755 Arkbuild/usr/bin/vulkaninfo

# Disable requirement for sudo for setting niceness
echo "ark              -       nice            -20" | sudo tee -a Arkbuild/etc/security/limits.conf

# Speaker Toggle to set audio output to SPK on boot
sudo mkdir -p Arkbuild/usr/local/bin
sudo cp scripts/spktoggle.sh Arkbuild/usr/local/bin/
sudo chmod 777 Arkbuild/usr/local/bin/spktoggle.sh
sudo chroot Arkbuild/ bash -c "(crontab -l 2>/dev/null; echo \"@reboot /usr/local/bin/spktoggle.sh &\") | crontab -"
sudo cp scripts/audiostate.service Arkbuild/etc/systemd/system/audiostate.service
sudo chroot Arkbuild/ bash -c "systemctl enable audiostate"

# Copy various other backend tools
sudo cp -R scripts/.asoundbackup/ Arkbuild/usr/local/bin/
sudo cp scripts/round_end.wav Arkbuild/usr/local/bin/
sudo cp scripts/checkbrightonboot Arkbuild/usr/local/bin/
sudo cp scripts/current_* Arkbuild/usr/local/bin/
sudo cp scripts/finish.sh Arkbuild/usr/local/bin/
sudo cp scripts/pause.sh Arkbuild/usr/local/bin/
sudo cp scripts/finish.sh.qm Arkbuild/usr/local/bin/
sudo cp scripts/pause.sh.qm Arkbuild/usr/local/bin/
sudo cp scripts/finish.sh Arkbuild/usr/local/bin/finish.sh.orig
sudo cp scripts/pause.sh Arkbuild/usr/local/bin/pause.sh.orig
sudo cp scripts/speak_bat_life.sh Arkbuild/usr/local/bin/
sudo cp scripts/spktoggle.sh Arkbuild/usr/local/bin/
sudo cp scripts/volume.sh Arkbuild/usr/local/bin/
if [ -d "scripts/${CHIPSET}" ]; then
  sudo cp scripts/${CHIPSET}/* Arkbuild/usr/local/bin/
fi
sudo cp scripts/timezones Arkbuild/usr/local/bin/
sudo cp scripts/BaRT_QuickMode.sh Arkbuild/usr/local/bin/
sudo cp scripts/"Enable Quick Mode".sh Arkbuild/usr/local/bin/
sudo cp scripts/"Disable Quick Mode".sh Arkbuild/usr/local/bin/
sudo cp scripts/arkos_ap_mode.sh Arkbuild/usr/local/bin/
sudo cp scripts/auto_suspend* Arkbuild/usr/local/bin/
sudo cp scripts/processcheck.sh Arkbuild/usr/local/bin/
sudo cp scripts/autosuspend.service Arkbuild/etc/systemd/system/
sudo chroot Arkbuild/ bash -c "systemctl disable autosuspend"
sudo cp scripts/keystroke.py Arkbuild/usr/local/bin/
sudo cp scripts/b2.sh Arkbuild/usr/local/bin/
sudo cp scripts/freej2me.sh Arkbuild/usr/local/bin/
sudo cp scripts/easyrpg.sh Arkbuild/usr/local/bin/
sudo cp scripts/get_last_played.sh Arkbuild/usr/local/bin/
sudo cp scripts/gx4000.sh Arkbuild/usr/local/bin/
sudo cp scripts/isitpng.sh Arkbuild/usr/local/bin/
sudo cp scripts/neogeocd.sh Arkbuild/usr/local/bin/
sudo cp scripts/netplay.sh Arkbuild/usr/local/bin/
sudo mkdir -p Arkbuild/etc/hostapd
sudo cp hostapd/hostapd.conf Arkbuild/etc/hostapd/
sudo cp dnsmasq/dnsmasq.conf Arkbuild/etc/
sudo cp scripts/sleep_governors.sh Arkbuild/usr/local/bin/
sudo cp scripts/wasitpng.sh Arkbuild/usr/local/bin/
sudo cp global/* Arkbuild/usr/local/bin/
if [ -f "device/${CHIPSET}/uboot.img.anbernic" ]; then
  sudo cp device/${CHIPSET}/uboot.img.anbernic Arkbuild/usr/local/bin/
fi
sudo cp scripts/Switch* Arkbuild/usr/local/bin/

# Disable winbind as connectivity to Active Directory is not needed
sudo chroot Arkbuild/ bash -c "systemctl disable winbind" 2>/dev/null || true
# Disable samba-ad-dc as well as some other services
sudo chroot Arkbuild/ bash -c "systemctl disable samba-ad-dc dnsmasq hostapd" 2>/dev/null || true
# Disable e2scrub_reap if ext file system is not being used for rootfs
if [ "$ROOT_FILESYSTEM_FORMAT" == "xfs" ] || [ "$ROOT_FILESYSTEM_FORMAT" == "btrfs" ]; then
  sudo chroot Arkbuild/ bash -c "systemctl disable e2scrub_reap" 2>/dev/null || true
fi
# Set the default target to multi-user instead of graphical
sudo chroot Arkbuild/ bash -c "systemctl set-default multi-user.target"

# Make all scripts in /usr/local/bin executable
sudo chmod 777 Arkbuild/usr/local/bin/*

# Link themes folder to /roms/themes and clone some themes
sudo rm -rf Arkbuild/etc/emulationstation/themes/
sudo chroot Arkbuild/ bash -c "ln -sfv /roms/themes/ /etc/emulationstation/themes"

# Link music folder to /roms/bgmusic
sudo rm -rf Arkbuild/home/ark/.emulationstation/music
sudo chroot Arkbuild/ bash -c "ln -sfv /roms/bgmusic/ /home/ark/.emulationstation/music"

# Set launchimage to PIC mode
sudo chroot Arkbuild/ touch /home/ark/.config/.GameLoadingIModePIC

# Set default volume
sudo cp audio/asound.state.${CHIPSET} Arkbuild/var/local/asound.state

# Set SDL Video Driver for bash
echo "export SDL_VIDEO_EGL_DRIVER=libEGL.so" | sudo tee Arkbuild/etc/profile.d/SDL_VIDEO.sh

# Set device name
dNAME=`echo $NAME | tr '[:lower:]' '[:upper:]'`
echo "$dNAME" | sudo tee Arkbuild/home/ark/.config/.DEVICE

# Configure default samba share setup
cat <<EOF | sudo tee -a Arkbuild/etc/samba/smb.conf
[roms2]
   comment = ROMS2
   path = /roms2
   browsable = yes
   read only = no
   map archive = no
   map system = no
   map hidden = no
   guest ok = yes
   read list = guest

[roms]
   comment = ROMS
   path = /roms
   browsable = yes
   read only = no
   map archive = no
   map system = no
   map hidden = no
   guest ok = yes
   read list = guest
   # On a dual-boot card /roms is Android's ext4: create what comes in over
   # the network rwx for user and group, so that ports run (no execute bit
   # otherwise) and Android keeps group write. FAT/exFAT ignore modes.
   create mask = 0777
   force create mode = 0770
   directory mask = 0777
   force directory mode = 0770

[opt]
   comment = OPT
   path = /opt
   browsable = yes
   read only = no
   map archive = no
   map system = no
   map hidden = no
   guest ok = yes
   read list = guest

[ark]
   comment = ark
   path = /home/ark
   browsable = yes
   read only = no
   map archive = no
   map system = no
   map hidden = no
   guest ok = yes
   read list = guest
EOF
sudo chroot Arkbuild/ bash -c "systemctl disable smbd" 2>/dev/null || true
sudo chroot Arkbuild/ bash -c "systemctl disable nmbd" 2>/dev/null || true

# Set distro identification and version
sudo mkdir -p Arkbuild/usr/share/plymouth/themes/
DARKOS_VERSION=${DARKOS_VERSION:-$(cat VERSION 2>/dev/null)}
if [ "$UNIT" == "rg52mini" ] && [ -n "$DARKOS_VERSION" ]; then
  DARKOS_TITLE="dArkOS ${DARKOS_VERSION} (${BUILD_DATE})"
  echo "${DARKOS_VERSION}" | sudo tee Arkbuild/home/ark/.config/.DARKOS_RELEASE
  # what darkos-ota updates from: a package applies to one BUILD_ID only
  cat <<EOF | sudo tee Arkbuild/etc/darkos-release
DEVICE=rg52mini
VERSION=${DARKOS_VERSION}
BUILD_ID=${DARKOS_BUILD_ID:-$(date -u +%Y%m%d%H%M%S)}
BUILD_DATE=${BUILD_DATE}
EOF
elif [ "$UNIT" == "ngp45ht" ] && [ -n "$DARKOS_VERSION" ]; then
  # NGP45HT keeps the date-based image name (setup_partition) but gets the OTA
  # metadata; its feed is ota/ngp45ht.json in this repo.
  DARKOS_TITLE="dArkOS ${DARKOS_VERSION} (${BUILD_DATE})"
  echo "${DARKOS_VERSION}" | sudo tee Arkbuild/home/ark/.config/.DARKOS_RELEASE
  cat <<EOF | sudo tee Arkbuild/etc/darkos-release
DEVICE=ngp45ht
VERSION=${DARKOS_VERSION}
BUILD_ID=${DARKOS_BUILD_ID:-$(date -u +%Y%m%d%H%M%S)}
BUILD_DATE=${BUILD_DATE}
EOF
else
  DARKOS_TITLE="dArkOS (${BUILD_DATE})"
fi
cat <<EOF | sudo tee Arkbuild/usr/share/plymouth/themes/text.plymouth
title=${DARKOS_TITLE}
EOF
# the date, as ArkOS tools have always compared it; the release is in
# .DARKOS_RELEASE
echo "${BUILD_DATE}" | sudo tee Arkbuild/home/ark/.config/.VERSION

# Set boot up welcome text
sudo cp scripts/boot_text.sh Arkbuild/usr/local/bin/
sudo chmod 777 Arkbuild/usr/local/bin/boot_text.sh
sudo cp scripts/welcome-message.service Arkbuild/etc/systemd/system/welcome-message.service
sudo chroot Arkbuild/ bash -c "systemctl enable welcome-message"

# Mark completed dArkOS updates with this current build
release_tags=( $(git -c 'versionsort.suffix=-' ls-remote --tags --sort='v:refname' https://github.com/christianhaitian/darkos-updates.git | cut -d/ -f3- | sed 's/^v//I') )
if [[ ! -z "$release_tags" ]]; then
  for release_tag in "${release_tags[@]}"
  do
    sudo touch Arkbuild/home/ark/.config/.update${release_tag}
  done
fi

# Set the owner of the ark folder and all sub content to ark
sudo chroot Arkbuild/ bash -c "chown -R ark:ark /home/ark"

# Clone some themes to the tempthemes folder
sudo mkdir Arkbuild/tempthemes
sudo git clone --depth=1 https://github.com/Jetup13/es-theme-freeplay.git Arkbuild/tempthemes/es-theme-freeplay
sudo git clone --depth=1 https://github.com/Jetup13/es-theme-minimal-arkos.git Arkbuild/tempthemes/es-theme-minimal-arkos
sudo git clone --depth=1 https://github.com/Jetup13/es-theme-nes-box.git Arkbuild/tempthemes/es-theme-nes-box
sudo git clone --depth=1 https://github.com/Jetup13/es-theme-switch.git Arkbuild/tempthemes/es-theme-switch
sudo git clone --depth=1 https://github.com/dani7959/es-theme-replica.git Arkbuild/tempthemes/es-theme-replica

sync
sudo umount -l ${mountpoint}

fat32_mountpoint=mnt/roms
mkdir -p ${fat32_mountpoint}
sudo mkdir -p Arkbuild/roms
while read GAME_SYSTEM; do
  if [[ ! "$GAME_SYSTEM" =~ ^# ]]; then
    echo -e "Creating ${fat32_mountpoint}/${GAME_SYSTEM}\n"
    sudo mkdir -p ${fat32_mountpoint}/${GAME_SYSTEM}
  fi
done <game_systems.txt

# Capable-device-only systems kept out of the shared game_systems.txt so weak
# rk3326 builds don't advertise them (upstream christianhaitian/dArkOS@5e1516a
# does this for rk3566).  RK3562 is binary-compatible with and as capable as
# rk3566, so create them here.  gc (Dolphin/GameCube) is the one we actually
# want; cdimono1/tigerlcd are still in game_systems.txt for us but listed here
# too for parity (mkdir -p is idempotent).
for extra_dir in cdimono1 gc tigerlcd
do
  echo -e "Creating ${fat32_mountpoint}/${extra_dir}\n"
  sudo mkdir -p ${fat32_mountpoint}/${extra_dir}
done

# PS2 emulation (pcsx2-sdl) needs specific subdirs visible on the ROMs
# partition before first launch, so users can drop BIOS files via SMB / USB
# without having to launch a game first to trigger the launcher's mkdir -p.
sudo mkdir -p ${fat32_mountpoint}/ps2/bios
sudo mkdir -p ${fat32_mountpoint}/ps2/memcards

# Default shutdown image, shown by finish.sh and pause.sh (upstream 2da67a0);
# game_systems.txt has already created the folder.
sudo cp shutdownimages/bye.gif ${fat32_mountpoint}/shutdownimages/
sudo mkdir -p ${fat32_mountpoint}/ps2/savestates

# Add latest version of PortMaster install to roms/tools folder
for (( ; ; ))
do
 PMver=$(curl --silent -qI https://github.com/PortsMaster/PortMaster-GUI/releases/latest | awk -F '/' '/^location/ {print  substr($NF, 1, length($NF)-1)}')
 wget -t 3 -T 60 --no-check-certificate https://github.com/PortsMaster/PortMaster-GUI/releases/download/${PMver}/Install.PortMaster.sh
 if [ $? == 0 ]; then
  break
 fi
 sleep 10
done
sudo mv -f Install.PortMaster.sh ${fat32_mountpoint}/tools/Install.PortMaster.sh
chmod 777 ${fat32_mountpoint}/tools/Install.PortMaster.sh

# Add latest version of ThemeMaster to roms/tools folder
for (( ; ; ))
do
 wget -t 3 -T 60 --no-check-certificate https://github.com/JohnIrvine1433/ThemeMaster/archive/refs/heads/master.zip
 if [ $? == 0 ]; then
  break
 fi
 sleep 10
done
sudo unzip -X -o master.zip -d ${fat32_mountpoint}/tools/
sudo rm -rf ${fat32_mountpoint}/tools/ThemeMaster
sudo mv -f ${fat32_mountpoint}/tools/ThemeMaster-master/ThemeMaster ${fat32_mountpoint}/tools/
sudo mv -f ${fat32_mountpoint}/tools/ThemeMaster-master/ThemeMaster.sh ${fat32_mountpoint}/tools/
sudo rm -rf ${fat32_mountpoint}/tools/ThemeMaster-master/
rm -f master.zip

# Get some sample pico-8 games
sudo rm -rf /roms/pico-8/carts/*
sudo wget -t 3 -T 60 --no-check-certificate https://www.lexaloffle.com/bbs/cposts/1/15133.p8.png -O ${fat32_mountpoint}/pico-8/carts/celeste.p8.png
sudo wget -t 3 -T 60 --no-check-certificate https://www.lexaloffle.com/bbs/cposts/sc/scrap_boy-6.p8.png -O ${fat32_mountpoint}/pico-8/carts/scrap_boy-6.p8.png
sudo wget -t 3 -T 60 --no-check-certificate https://www.lexaloffle.com/bbs/cposts/di/dinkykong-0.p8.png -O ${fat32_mountpoint}/pico-8/carts/dinkykong-0.p8.png
sudo wget -t 3 -T 60 --no-check-certificate https://www.lexaloffle.com/bbs/cposts/po/poom_0-9.p8.png -O ${fat32_mountpoint}/pico-8/carts/poom_0-9.p8.png
sudo wget -t 3 -T 60 --no-check-certificate https://www.lexaloffle.com/bbs/cposts/ch/cherrybomb-0.p8.png -O ${fat32_mountpoint}/pico-8/carts/cherrybomb-0.p8.png

# Copy default game launch images
if [ -f "launchimages/loading.ascii.${UNIT}" ]; then
  sudo cp launchimages/loading.ascii.${UNIT} ${fat32_mountpoint}/launchimages/loading.ascii
else
  sudo cp launchimages/loading.ascii.353m ${fat32_mountpoint}/launchimages/loading.ascii
fi
if [ -f "launchimages/loading.jpg.${UNIT}" ]; then
  sudo cp launchimages/loading.jpg.${UNIT} ${fat32_mountpoint}/launchimages/loading.jpg
else
  sudo cp launchimages/loading.jpg.353m ${fat32_mountpoint}/launchimages/loading.jpg
fi

# Copy various tools to roms folders
sudo cp -a ecwolf/Scan* ${fat32_mountpoint}/wolf/
sudo cp -a scummvm/scripts/Scan* ${fat32_mountpoint}/scummvm/
sudo cp -a hypseus-singe/scripts/Scan* ${fat32_mountpoint}/alg/
sudo cp -a scummvm/scripts/menu.scummvm ${fat32_mountpoint}/scummvm/

# Clone some themes to the roms/themes folder
sudo git clone --depth=1 https://github.com/Jetup13/es-theme-nes-box.git ${fat32_mountpoint}/themes/es-theme-nes-box
sync

# Create roms.tar for use after exfat partition creation
sudo tar -C mnt/ -cvf Arkbuild/roms.tar roms

# Remove and cleanup fat32 roms mountpoint
sudo chmod -R 755 ${fat32_mountpoint}
sync

sudo rm -rf ${fat32_mountpoint}

echo "Finishing touches complete for RK3562"

# Report what did not make it into the image, while Arkbuild is still mounted
# and before cleanup_filesystem.sh removes the sources. Informational only.
bash scripts/audit-components.sh Arkbuild build.log
