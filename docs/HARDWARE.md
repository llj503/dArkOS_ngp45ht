# Hardware fixes

Four patches carried in [mamaich/kernel_rk3562](https://github.com/mamaich/kernel_rk3562),
on top of bmdhacks' `557e5c28a`. They were written and tested against the
Android port of this device and replayed onto this tree; the trees share no
history, so they were applied as patches rather than merged.

    ad4b47f2e  Type-C role switching, speaker click fix, Bluetooth over SDIO
    b5c61cb7d  usb: dwc3: backport the LOA babble filter quirk
    9e1972482  arm64: dts: rg52mini: add the high temperature voltage limit
    db0453bd6  ASoC: rk817: program the ADC sample rate register

## USB host — needs the Type-C controller described

The connector has no ID pin. Role is decided over the CC lines by an HUSB311,
and if the device tree does not describe it, dwc3 stays a peripheral forever:
`/sys/bus/usb/devices/` is empty, without even a root hub.

What has to be there:

* `i2c@ffa10000` enabled, with `husb311@4e`, `compatible = "hynetek,husb311"`,
  interrupt on GPIO0 pin 15, `vbus-supply` pointing at the RK817 `OTG_SWITCH`
  regulator, and a `connector` subnode of type `usb-c-connector` with
  `data-role`/`power-role` dual;
* `usb-role-switch` on `usb@fe500000`. Not extcon — the extcon path from
  usb2-phy waits for an ID pin that does not exist.

Kernel side needs `TYPEC`, `TYPEC_TCPM`, `TYPEC_TCPCI`, `TYPEC_HUSB311` and
`USB_ROLE_SWITCH`; `rg52mini_defconfig` already had all of them, so only the
device tree was missing.

Verified on hardware: plugging in a mouse brings up xHCI and enumerates it.

    xhci-hcd xhci-hcd.1.auto: xHCI Host Controller
    usb 1-1: Product: USB Optical Mouse, Manufacturer: PixArt
    hid-generic 0003:093A:2510.0001: USB HID v1.11 Mouse

`/sys/class/typec/port0/data_role` shows `host [device]` while the port is
connected to a PC and flips when a device is attached — the brackets mark the
current role, so an empty `/sys/bus/usb/devices/` is expected in device mode
and is not a fault.

There is one open loose end: the kernel logs

    OF: graph: no port node found in /i2c@ffa10000/husb311@4e/connector

so the port/endpoint graph between connector and controller is not fully
described, even though role switching works anyway. `backup/dtb/live.dtb`
(dumped from the vendor's EmuELEC) has the complete binding and is the
reference if this ever needs tightening.

## Bluetooth — the driver branch nobody compiled

The AIC8800 driver ships with Bluetooth over SDIO disabled, and the branch
does not build when it is turned on: `CONFIG_SDIO_BT=y` is needed in both
Makefiles, `CONFIG_BLUEDROID` has to be 0 to get the BlueZ path rather than
the Android one, and `hci_dev_get` collides with the kernel's own symbol and
needs renaming. The Android branch (`/dev/aicbt_dev`) is written for kernels
with `CONFIG_BT` off and will not compile here at all.

Verified on hardware:

    hci0: Type: Primary  Bus: SDIO
          BD Address: 0B:3B:22:AC:88:20
          UP RUNNING
    aic8800_fdrv  536576  0
    aic8800_bsp    98304  1 aic8800_fdrv

Module order matters: `aic8800_bsp` first, then `aic8800_fdrv`. The driver
powers the chip itself when it loads, so until the module is up the SDIO bus
looks empty — "SDIO is broken" almost always means "the module did not load".
Bluetooth needs the combo firmware `fmacfwbt_8800d80_h_u02.bin`; the driver
picks it on its own. All 15 D80 blobs ship in `BSP/firmware/aic8800/` and land
at `/lib/firmware/aic8800`, which is what `CONFIG_AIC_FW_PATH` points at.

## Bluetooth gamepads need the HID gate opened

A pad can pair, report `Connected: yes`, and still produce no input device at
all. Nothing in the UI says why; the only trace is one line from the daemon:

    profiles/input/device.c:hidp_add_connection()
    Rejected connection from !bonded device /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX

BlueZ refuses HID from a device it does not consider bonded, and has done by
default since 5.6x — `ClassicBondedOnly`, true unless told otherwise. Plenty of
gamepads pair the old way and never bond: `bluetoothctl info` shows
`Paired: yes`, `LegacyPairing: yes`, `Bonded: no`, and that is enough to be
turned away.

`finishing_touches-rk3562.sh` writes `ClassicBondedOnly=false` into
`/etc/bluetooth/input.conf`. With it, the same pad brings up two nodes — the
joystick and a consumer-control keyboard — and EmulationStation picks them up
without being restarted:

    N: Name="GamepadPlus"                  H: Handlers=js1 event7
    N: Name="GamepadPlus Consumer Control" H: Handlers=kbd event6

The trade is real and was made deliberately: an unbonded HID link can be
spoofed, and a spoofed HID link is keystrokes. On a handheld that stores no
credentials, against an alternative of "Bluetooth gamepads do not work", it is
the right way round.

The kernel side needs nothing: `BT_HIDP`, `UHID`, `HIDRAW`, `HID_GENERIC`,
`INPUT_JOYDEV` and `INPUT_EVDEV` are all built in, and `hidp` registers at boot
(`Bluetooth: HIDP (Human Interface Emulation) ver 1.2`). If a pad is missing,
read the daemon log before touching the kernel.

There is no equivalent of Android's vendor Bluetooth HAL here, and none is
needed: BlueZ brings up the HID channel, the kernel turns it into
`/dev/input/event*`, SDL2 hands it to EmulationStation.

## Speaker click

The external amplifier is switched by `gpio-115` (`spk-ctl`). The RK817 codec
driver raises it on DAC unmute and drops it on mute, with the delays given by
`spk-mute-delay-ms` and `hp-mute-delay-ms`. Only the headphone delay was in
the tree, so the amplifier switched right on the DAC transition and it was
audible. `spk-mute-delay-ms = <100>` was added.

Check with `cat /sys/kernel/debug/gpio | grep spk`: in silence it should read
`out lo`. It does. Whether the click is actually gone has not been confirmed
by ear.

## Babble filter

A bad cable or static can fake a "babble" condition in the idle window between
EOF2 and the next SOF; xHCI treats it as an error and disables the whole root
port — `usb usb1-port1: disabled by hub (EMI?)`. `GUCTL1.LOA_FILTER_EN` makes
the controller require three consecutive confirmations. This is a backport of
William Wu's commit from `rockchip-linux/kernel`, which landed after this tree
was branched, and it needs both halves: the driver change and
`snps,loa-filter-en-quirk` in the device tree.

Active on the device: `dwc3 fe500000.usb: enable loa filter for port babble`.

## Thermal ceiling

Without `rockchip,high-temp` the system monitor leaves its threshold at
`INT_MAX` and never acts. `rockchip,high-temp = <95000>` and
`rockchip,high-temp-max-volt = <1100000>` are device-tree only; the 5.10
`rockchip_system_monitor` driver already parses both.

This is not the same thing as the GPU throttling described in
[PERFORMANCE.md](PERFORMANCE.md), which is a separate governor and a separate
problem.

## ADC sample rate

`hw_params()` programmed only the DAC rate register, leaving the ADC one set
for 48 kHz. Recording at 16 kHz therefore ran with a misconfigured converter.
Confirmed by reading the register on a live device. It does not affect the
built-in microphone, which is dead in hardware (this reproduces under EmuELEC
with the vendor's own device tree, so it is not a firmware problem), but it
does affect a headset.

## The graphics stack

Read off the blobs and the config rather than from documentation, 2026-09-16.

| | |
|---|---|
| OpenGL ES | 3.2, plus legacy ES-CM 1.1 |
| EGL | 1.5, with the Mali AFBC/AFRC framebuffer-compression extensions |
| Vulkan | 1.3, through the same blob |
| OpenCL | exported by the blob |
| Desktop OpenGL | software only — see below |

The hardware path is ARM's `libmali-bifrost-g52-g29p1.so`, 57 MB, installed as
`libMali.so` with `libEGL`, `libGLESv2`, `libgbm` and friends symlinked onto it
by `build_deps.sh`. Vulkan comes from the same file: it exports
`vk_icdGetInstanceProcAddr`, and `finishing_touches` installs
`BSP/vulkan/rk_vk.json` (`api_version 1.3.276`) pointing at it, a vendor
`libvulkan.so.1.3.274` loader and `vulkaninfo`. `cleanup_filesystem.sh` deletes
the Mesa ICDs so only the Mali one is left.

**There is no hardware desktop OpenGL, and there cannot be.** ARM's blob does
not implement it — no `glBegin`, no GLX. Mesa is installed and provides
`libGL.so.1`, `libGLX_mesa` and a `dri` directory that includes
`panfrost_dri.so`, but panfrost cannot attach to this kernel: the GPU is driven
by ARM's own kbase — `CONFIG_MALI_BIFROST`, from `drivers/gpu/arm/bifrost`,
because the GPU node in `rk3562.dtsi` says
`compatible = "arm,mali-bifrost"` — and `CONFIG_DRM_PANFROST` is not set. So anything that asks for desktop GL gets
llvmpipe, which will report a respectable OpenGL 4.5 and rasterise it on four
Cortex-A53 cores.

The practical rule: an emulator that speaks GLES or Vulkan runs on the GPU, and
one that needs desktop GL will start and be unplayable. That is why the recipes
here pass `USE_EGL=ON` and `USING_FBDEV=ON`.

**Two other Mali drivers used to be compiled and could never bind.** This
kernel carries three trees under `drivers/gpu/arm`: `bifrost`, `midgard` and
`mali400` (Utgard, for Mali-400/450). Only bifrost can probe here, yet
`CONFIG_MALI_MIDGARD` and `CONFIG_MALI400` were both `y` — 438 and 113 symbols
of dead driver in `System.map`. Both are off as of v09292026.

`MALI_DT`, `MALI_DEVFREQ` and `MALI_SHARED_INTERRUPTS` sit beside them in the
defconfig and read as if they were shared, but they are declared in
`drivers/gpu/arm/mali400/mali/Kconfig` and belong to Utgard alone. Bifrost has
its own `MALI_BIFROST_DEVFREQ`, which stays on. Checked before switching
anything off: nothing outside `drivers/gpu/arm` depends on either driver.

The 32-bit armhf side is GLES 3.2 as well, but from the older `g13p0` blob.
`build_deps.sh` picks it deliberately: the 32-bit build of g29p1 segfaults
inside libmali during GL and shader setup (SEGV_ACCERR).

## A silent RGB bridge used to black the screen

`rockchip_rgb` looks for the RK628 bridge and returned `-EPROBE_DEFER` for
ever when it did not answer on i2c. DRM binds whole or not at all, so an RGB
output nobody needs took the working DSI panel with it: black from the moment
the kernel started, on hardware where the panel is fine.

It now waits while initcalls are still running, as before, and binds without
the RGB output once the kernel has given up. Only HDMI through that bridge is
lost. `a9450795f`, ported from `mamaich/kernel_rk3562_rg52mini` `f90073f66`.

This matters on boards where the bridge is damaged, unpopulated or absent —
it is not specific to one revision.

## Two Wi-Fi chips on one power rail

Two RG52 Mini revisions put different chips on the same `wireless-wlan` node
and the same rail: RK915 (SDIO vendor `0x0296`) and AIC8800 (`0xc8a1`). Both
drivers pulse `rockchip_wifi_power()` at module init, so loading both in
sequence leaves the second one having cut power under the first.

Handled, and worth not re-deriving:

* `wifi-driver-load.service` runs `wifi-driver-load.sh`, which tries `rk915`
  first and falls back to `aic8800_bsp` + `aic8800_fdrv` only if that fails;
* `modprobe.d/dArkOS-wifi.conf` blacklists both aic8800 modules, because udev
  would otherwise autoload them off the SDIO vendor id while rk915's probe is
  still cycling the rail, and the firmware download dies mid-flight.

The fallback keys on `modprobe` failing rather than on the interface
appearing. That is weaker in principle — a module can load and bind nothing —
but it is what works on both revisions in practice: `rk915` fails to
initialise where its chip is absent.

## Diagnostics

`DETECT_HUNG_TASK`, `SOFTLOCKUP_DETECTOR`, `WQ_WATCHDOG` and `PSTORE_PMSG` are
on, none of them set to panic. `PSTORE_RAM` was already on, so whatever the
last hang logged survives into the next boot — look in `/sys/fs/pstore`.

`DEBUG_CREDENTIALS` is off: it validates cred structures on every access, and
this device runs only what its own image contains. `HARDENED_USERCOPY` and
`ARM64_SW_TTBR0_PAN` are off for the same reason. `cf236becd`.

## The bootloader

The image ships `mamaich/u-boot-rk3562-rg52mini`, branch `next-dev`, written
to the `uboot` partition at sector 16384 by `build_kernel-rk3562.sh` from
`BSP/uboot-rg52mini.img`. The vendor's own U-Boot is kept beside it as
`.vendor`.

v10052026 ships `uboot-oc-stocktee-shmkept.img`
(`next-dev-g6eeb07c058-dirty`, md5 `0e743c774c9892195715251dd2262ade`): the
stock BL32 v1.07 (`3.13.0-891-g9f2aca7d1`, 473472 bytes in the FIT) and a BL31
whose frequency tables carry the overclocking entries from `05-разгон.md` in
the U-Boot fork. Those entries only matter if the kernel asks for those rates,
and this kernel does not: its CPU table ends at 2016 MHz. The name says the
SHM patch below is kept.

v09292026 shipped the build made from `uboot-bl32-v102.img`
(`next-dev-g66a8e67e16`): BL32 v1.02 in the FIT instead of v1.03, and the SHM
patch described below.

It replaces a stock `U-Boot 2017.09` that ran with `rk3562-evb`, the Rockchip
evaluation-board device tree: twelve kilobytes with no dsi, panel, vop or
route nodes, which is why nothing the earlier notes here tried ever put a
picture on the screen. This one brings power-off, exit from charge mode,
the splash, the charge animation, the LED at power-on and a working console.

What it wants from this side, all on the boot partition (partition 3, the FAT
one, which carries the GPT legacy-bootable attribute — that is how U-Boot
finds it):

| | |
|---|---|
| `rk3562-rg52mini.dtb` | **required**, exactly that name. U-Boot runs on it, and without it the screen stays black although the device boots |
| `logo.bmp` | the splash, 720x1280 |
| `battery_0..5.bmp`, `battery_fail.bmp` | charge animation, 220x110, drawn centred |
| `extlinux/extlinux.conf` | how it finds the kernel, last of four boot methods it tries |

The BMPs must be **24-bit and uncompressed**. The vendor's charge frames are
8-bit RLE and this U-Boot will not draw them, which is a silent failure —
hence the copies in `BSP/`, taken from the release.

**Never ship `logo_kernel.bmp`.** U-Boot hands that file to the kernel so the
picture survives the handover, and on this device the handover blanks the
panel: boot proceeds normally and the screen goes black the moment the system
reaches the display. `build_kernel-rk3562.sh` deletes it defensively.

The resource partition is empty on this device, so everything the vendor would
normally keep there is read off the boot partition as ordinary files.

### OP-TEE is not used, and its memory is given back

Nothing in this image talks to the secure world. No `/dev/tee*` consumer
ships, `tee-supplicant` is not installed, and vendor storage goes through
`CONFIG_ROCKCHIP_VENDOR_STORAGE` rather than OP-TEE, so the MAC address and
serial number do not depend on it.

Two halves, and they have to match:

* Up to v09292026 the bootloader carried **BL32 v1.02**, which declares an
  8 MiB OP-TEE region where later blobs declare 10 MiB; v10052026 is back on
  the stock v1.07 and gives those 2 MiB up again. `param_parse_optee_mem()` in
  `arch/arm/mach-rockchip/param.c` hands the 2 MiB SHM window at the tail of
  that region back to Linux.
* The kernel is built with **`CONFIG_TEE` and `CONFIG_OPTEE` off**. Had the
  driver come up it would have negotiated that same window as shared memory
  and both sides would be writing the same pages.

The `firmware/optee` node in `rk3562-linux.dtsi` stays. Without the driver it
does nothing, and that file is shared with the Android work on this board,
where the node is what stops a vendor self-check from rebooting in a loop.

None of this touches the vendor firmware, which boots from eMMC through a
different chain of bootloaders.

### The console

The TX/RX/GND pads are `uart0m0` (GPIO0_D0/D1), 1500000 8N1, 3.3 V; do not
feed power from the adapter, and note that not every USB bridge will do that
rate. The kernel's own console rate is separate — `rockchip,baudrate` in the
`fiq-debugger` node — and is already `1500000` here, which is what keeps the
port readable across the handover.

Do not move the port to `uart0m1` (GPIO1_B3/B4): those pins are the SD card's
data bus and the device stops booting. The same goes for `uart5m0` and
`uart7m1`.

**U-Boot rewrites the command line's first `console=` rather than appending
its own.** Here both sides name the same thing, so nothing moves — but it
means a `console=` added for debugging will be the one that disappears, and
that a second console has to go after the first to survive. It is also the
reason dropping `console=tty1` for the boot logo is safe: what U-Boot
substitutes is its serial console, never a vt.

### Charging

With a cable attached the device enters charge mode and does not boot. Hold
power for about three seconds to leave it; a short press does nothing. On the
serial port this shows as `Exit charge animation...`. After leaving charge
mode the splash is drawn, so the last battery frame does not stay on screen.

## Boot logo, kernel side

The kernel draws its own logo after U-Boot's — `CONFIG_LOGO` plus
`BSP/logo_linux_clut224.ppm.gz`, which `build_kernel-rk3562.sh` unpacks into
`drivers/video/logo/` before building. The artwork is the vendor's, lifted
from the EmuELEC boot partition and rotated counter-clockwise to 1280x720 so
that `fbcon=rotate:1` turns it upright.

Two things outside the kernel are required, both in the command line built by
`finishing_touches-rk3562.sh`:

* `loglevel` above 4, because fbcon skips the logo when
  `console_loglevel <= CONSOLE_LOGLEVEL_QUIET`;
* no `console=tty1`, or the boot log is printed over it.

Both halves — bootloader and kernel — first ship in the 2026-09-16 image.
Watch out for the trap that kept the kernel half out of it on the first
attempt: see the `.config` note in BUILDING.md.
