# What is next

A working list, not a roadmap. Ordered by what a build would answer soonest.

## Shipped in v09162026

All of it is on the device and released, so it is history rather than a list to
work through: the boot logo from both halves, `Playback Path = SPK` by default,
zram on lzo-rle with the eMMC partition as a second tier, stripped modules,
Cortex-A53 flags for everything that rebuilt, Kodi, Yabasanshiro, freej2me-plus,
our own U-Boot, and the component audit that runs at the end of every build.

The kernel changes that landed after the build finished — the RK628 bridge
fix, the hang detectors, the bootloader log — were rebuilt and written into the
released image by hand rather than left waiting.

## Shipped in v09292026

Everything the previous list was waiting on, plus what was found while building
it. Confirmed on the device.

* **flycast and fake-08 are optimised now** — they had been built at `-O0` and
  `-g`. PPSSPP's `flags.make` was read out of the running build to prove the
  flags arrive, and the cache key change meant it rebuilt from source rather
  than restoring the artifact made under the old flags.
* **`perfmax` sets the GPU governor**, which it never did on this SoC — it was
  writing to the RK3566 node, so every game ran on `simple_ondemand`.
* **BlueZ accepts HID from unbonded devices**, which is most legacy Bluetooth
  gamepads. It was in the released image by hand; now it is in the build.
* **The Bluetooth driver no longer frees every failed packet twice.**
  `bt_sdio_recv()` in aic8800 called `kfree_skb()` after `hci_recv_frame()`
  had already freed it — 150 to 200 double frees per shutdown with Bluetooth
  on, a corrupted slab, and a panic somewhere unrelated a moment later. See
  KNOWN-ISSUES.
* **The two GPU drivers that cannot bind here are gone**, and so is the
  debugging the device never reads: `Image` is 6.0 MB smaller. See
  PERFORMANCE and HARDWARE.
* **OP-TEE is off on both sides** — driver and bootloader — which returns the
  2 MiB SHM window. See HARDWARE. (v10052026 went back to the stock BL32
  v1.07, whose region is 2 MiB larger.)
* **RetroArch gets its cores even when GitHub says 429.** 269 cores
  downloaded, 8 of them only after a retry; plain `wget -t` counts network
  failures and treats an HTTP error as a final answer, so those 8 used to go
  missing silently.
* **A workaround for the revision A black screen**, added to the assets on
  2026-10-03: `panel-kick` re-initialises the display before EmulationStation,
  letting the DSI host and its PHY runtime-suspend first. The mechanism was
  found on revision B; confirmed working on a revision A unit by its owner.
  KNOWN-ISSUES has the evidence.

## Check on the device what the upstream sync of 2026-10-05 brought

The sync with christianhaitian/dArkOS and rk3566_core_builds (see the commits
of that date) was done by reading, not by running. Each of these needs a look
on the device after the next build:

1. **DSperate** — checked on the device on 2026-10-07 (v10062026, revision B),
   with the Pokemon Diamond & Pearl and Dragon Quest Monsters Joker 2 demos and
   the BIOS and firmware dumps in /roms/bios:
   * **Rotation: fine.** It does not take the KMS page-flip path on this panel
     ("drm: display 0 has no 1280x720 mode (panel is 720x1280)"); it presents
     through an SDL window surface on KMSDRM, so our SDL rotation patch turns
     the picture. Both DS screens stacked, centred, upright.
   * **Input: fine.** nds.sh's RG52 mapping is picked up; DSperate notices that
     SDL's a/b and x/y are swapped against the kernel's button positions and
     corrects it itself. Start+Select quits.
   * **Sound** through ALSA at 48 kHz; one underrun at start.
   * **Speed is the CPU governor, not the build.** Pokemon DP demo, first
     field, walking; clocks sampled twice a second for 10 s:

     | | ondemand (CPU) / simple_ondemand (GPU) / dmc_ondemand | performance |
     |---|---|---|
     | fps | 41-47, audio underruns | 60, none |
     | CPU | 816-2016 MHz, under 1.5 GHz a third of the time | 2016 MHz |
     | GPU | 300 MHz | 900 MHz |
     | DMC | 928 MHz | 928 MHz |

     DSperate keeps about one core busy, which ondemand reads as light load.
     The 3D field of the Joker 2 demo behaves the same way: 48 fps under
     ondemand, 59-60 under performance. Nothing in the image changes this
     (decided 2026-10-07); KNOWN-ISSUES tells users to pick the performance
     governor for NDS in ES.
   * **Vulkan, in the image since 2026-10-07.** The first 10062026 build had
     DSperate without Vulkan ("gpu3d: unavailable (built without Vulkan)"):
     the presenter and GPU 3D raster need `vulkan/vulkan.h` at build time and
     the chroot had no libvulkan-dev. build_dsperate.sh now installs it (cache
     key suffix `_vk`), the v10062026 image carries that build, and
     dsperate.ini.rk3562 sets `gpu3d = true`. On the device it logs
     "gpu3d: on". In the two demos it made no measurable difference to the
     frame rate - the governor is what matters there - but it moves 3D off the
     CPU for heavier games. Existing cards keep their /roms/nds/dsperate/
     dsperate.ini; nds.sh copies the new default only where there is none.
   * Not yet checked: the stylus on the stick, savestates, a heavier 3D game.
2. **Dolphin hotkeys** — the one recompiled emulator (patch 012).
3. **PPSSPP-2021** now keeps its config and saves in /roms/psp/ppsspp-2021.
   Saves made with it before are still in /roms/psp/ppsspp and are not moved.
4. **Shutdown image** (bye.gif through ffplay in finish.sh / pause.sh): does
   it show the right way up through our SDL rotation?
5. **wifi_importer**: a wifikeyfile.txt in Tools is imported at boot.
6. Not taken, to be decided on the device: libOpenCL.so symlink (upstream
   says it breaks video previews), Dolphin Stretch option, batteryplus,
   headphone auto-switch (needs kernel work), bluealsa conf path.

## Revision A black screen: fixed — decide whether panel-kick can go

What breaks the panel is known (KNOWN-ISSUES): switched off and on again too
quickly, with no delays in its exit sequence, it stays black. Fixed in the
kernel by the stock exit-sequence delays (`23506d78f`) and a 500 ms minimum
DSI off time (`7483a4f83`, from the Android port). panel-kick, which cured
revision A by keeping the display off for about 0.24 s, stays until that is
confirmed. In order:

The fix was confirmed on a revision A unit (v10032026-test, 2026-10-04) and
is in the v09292026 assets. What is left is whether panel-kick is still needed:

1. Test on revision A with `/boot/panel-kick-off`:
   if the picture comes up by itself, panel-kick can go. `link off … waiting`
   in `dmesg` tells whether a fast cycle happened.
2. If it still goes black with `panel-kick-off`, the cycle is not the cause.
   The other candidates: a failed warm takeover of the U-Boot link on the
   first enable, where nothing was switched off before and the off-time wait
   cannot act; or rk915 power-cycling the Wi-Fi rail around the time the
   display first comes up. A `dmesg` from the unit decides between them.
3. Does v09162026 also go black on revision A? Still unasked, and it says
   whether something between the releases introduced it.

## HDMI: find the real connector name, then make detection follow the cable

HDMI does nothing on the device. KNOWN-ISSUES has the evidence that the kernel
side matches the Android image where HDMI works, so this is dArkOS-side work.
In order, and the first step is one command:

1. **Ask the card what its connectors are called.** On the device:

       ls /sys/class/drm/
       for c in /sys/class/drm/card0-*/status; do echo "$c $(cat $c)"; done

   HDMI arrives through `route-rgb` and the RK628, so expect something other
   than `HDMI-A-1`. Whatever the name is, it has to replace the hardcoded one
   in `scripts/rk3562/hdmi-test.sh` and in `KCMD_VIDEO` in
   `finishing_touches-rk3562.sh`, which currently says
   `video=HDMI-A-1:1280x720@60`.

2. **Read the connector index rather than assuming it.** The script writes
   `drmConn=1` for HDMI and `0` for the panel. The index EmulationStation and
   RetroArch expect is a position on the card, so derive it from the same
   enumeration as step 1 instead of hardcoding.

3. **Make it run on hotplug, not only at boot.** It is on `@reboot` in crontab
   today. There is already a udev rule firing on DRM events —
   `audio/99-hdmi-audio.rules`, `SUBSYSTEM=="drm"` — which calls
   `audio-switch.sh`. Call the display side from the same place so plugging a
   cable does something.

4. **Drop the `2>/dev/null` while debugging.** It is what turned "that path
   does not exist" into "no display connected", which is why this looked like a
   hardware problem for a while.

Worth knowing before touching the kernel: `rockchip_rgb` binds without the RGB
output if the bridge has not answered by the time initcalls finish, so if the
connector is genuinely absent from `/sys/class/drm`, check `dmesg` for the rgb
and rk628 probe order before concluding anything about the hardware.

## Open questions on the device

* **Is the speaker click gone?** `spk-mute-delay-ms = <100>` is in the device
  tree and the GPIO reads `out lo` in silence, which is necessary but does not
  prove the click went away. Needs an ear.
* **Does a USB mouse do anything?** It enumerates and binds `hid-generic`, and
  an input node appears, but no cursor is visible. EmulationStation may simply
  not use one — that would be expected, not a fault.
* **`OF: graph: no port node found`** in the husb311 connector. Role switching
  works anyway. `backup/dtb/live.dtb` from the vendor's EmuELEC has the
  complete port/endpoint graph if this is ever worth tightening.

## Decisions nobody has made yet

* **Charging parameters.** The device tree carries the numbers from the
  Android port (4300/300/4654/78/2800); the vendor's own `live.dtb` says
  4280/150/4642/69/3400. The difference that matters is `power_off_thresd`,
  2800 against 3400 mV — the vendor stops much earlier. Deep discharge is
  harder on a cell than a shorter runtime is on a user, so the vendor value is
  probably right, but it is a battery decision and should be made on purpose.
* **Thermal headroom.** Raising `trip-point-1` or `sustainable-power` would buy
  measurable performance and has been deliberately refused; PERFORMANCE.md
  explains why and what to do instead. Open only in the sense that a heatsink
  would change the answer.
* **`CONFIG_ZRAM_WRITEBACK`.** Compiled in, unused. It is the other way to
  spend the eMMC partition — see PERFORMANCE.md.

## Repairs, each its own small job

* Three bit-rotted patches: ECWolf, Hypseus Singe, GameTank.

Described in KNOWN-ISSUES.md with what was already ruled out.

The seven PortMaster compatibility libraries that used to 404 are fixed:
upstream found them on snapshot.debian.org and this fork took the change. All
twenty-one URLs answer now.

Done since this list was written: Yabasanshiro, whose upstream repository is
gone, builds from a pinned commit of a surviving fork; freej2me-plus needed a
java level a current JDK still accepts and a jar name that had been renamed
under it; and Kodi's two patch conflicts are resolved and built.

## RetroArch fixes after v1.22.2 that need porting by hand

The 1.1 build carries upstream's fixes that apply as they are
(`retroarch-patch-0021`, `-0022`). These are in v1.22.2 too, but master
rewrote the code around them, so each needs a small port. Recheck whether a
tag newer than v1.22.2 has appeared first: moving to it would replace all of
this.

* **HTTP client against a hostile server** (66155ff344, eb86df008d). With
  both Content-Length and chunked, the chunk parser reads wild. A huge chunk
  length or a negative Content-Length gets through, and `realloc` results go
  unchecked. The updater talks plain http, so anyone on the network can be
  the server. Port: `response->len = 0` on entering `P_BODY_CHUNKLEN`,
  Content-Length as `size_t` capped at 256 MiB, a capped chunk length, and
  checked reallocs.
* **Cloud sync path traversal** (4ee62a575f, its `cloud_sync` part). A
  hostile server writes outside the sync directory. Matters only if cloud
  sync is turned on.
* **Network commands** (fa49a43dc2). `READ_CORE_RAM` with a large count
  wraps the allocation size, and one UDP packet to port 55355 overflows the
  heap. Off unless `network_cmd_enable`, which Quick Mode turns on; since 0023 the socket listens on 127.0.0.1 only, so it is local. Port:
  cap the byte count at 16 KiB.
* **Saves and config survive a power cut** (250e2d1b48, bb583943fd,
  b867454de3 with d20c1a344e, edb8facc19, 163ef5e698). Write a temporary
  file and rename it, not in place.
* **ALSA can wait forever** (48394abbb2, 6abd13a0d1). Use a finite timeout
  for `snd_pcm_wait`.
* Smaller, clean or nearly so:
  * 9a19e7a94d: netplay client number from the host, one hunk by hand;
  * c7a261ce54: ozone selection past a shrunk playlist;
  * 3eedad0aa5: autosave thread after core deinit;
  * db91cdbf89: gl2.c GLES 3 context for cores;
  * e092c37228, d5e598aedc, f85119508e;
  * 44a041cf96: decompress use-after-free, by hand.

## Worth sending upstream

Five build-system defects were fixed in this fork. Three of them have nothing
to do with this hardware and would help anyone building dArkOS, so they belong
in a pull request to bmdhacks rather than only here:

| | |
|---|---|
| `utils.sh` | `install_package`'s `updateapt` flag is global, so the 32-bit chroot never gets contrib/non-free and never runs `apt update` |
| `setup_partition-rk3562.sh` | the result of `mount` was not checked — a failed mount let the build write past the image for hours |
| `build_retroarch.sh` | `while true` with no attempt counter, which turns one broken patch into a build that spins overnight |
| `utils.sh` | `protect_package` reports `"$${protectedlib} has been marked..."` — `$$` is the shell PID, so every line reads `531{protectedlib}` and never names the package |

The other two — the absolute toolchain path and the 32-bit chroot cloning
upstream's core builds instead of the local fork — only bite in this fork's
layout.

### gl4es: render targets left with a mipmap filter

The report is drafted in `gl4es-fix/UPSTREAM.md`, for an issue at
ptitSeb/gl4es. It is not posted yet: the owner decides when. It covers two
things:
- render-target textures keep `GL_NEAREST_MIPMAP_LINEAR` on the GLES side;
- `SAMPLER[n]` sized by nested macros comes out too small.

Before posting:
- check another gl4es port with the 1.1 image, so that the report can say
  whether more than Don't Starve is affected;
- if possible, build gl4es with one of the two suspected spots changed, and
  name the cause instead of a suspicion.

Once gl4es is fixed upstream and ports carry the new build, `gl4es-fix/` and
its line in `portmaster-e2big.sh` can go.

## The dependency stage costs two hours of emulation, not of work

Measured while resuming the 2026-09-29 build, where every package was already
installed and the stage still took the same order of time: about 34 seconds per
entry in `needed_packages.txt`, against 41 seconds when they were being
installed for real. Almost none of that is installing anything.

Each entry of that list runs two separate commands inside the arm64 chroot, and
every one of them is a full process start under qemu:

* `install_package` -> `chroot Arkbuild dpkg -s <pkg>:arm64`, purely a question
* `protect_package` -> `chroot Arkbuild apt-mark manual <pkg>`

`needed_dev_packages.txt` runs at half that, near 17 seconds, because its
`protect_package` call is commented out — which is the measurement that says
where the time goes.

Two ways out, both straightforward:

* Batch. `apt-mark manual` and `dpkg -s` both take any number of package names,
  so the whole list is one chroot invocation instead of 101 or 202.
* Ask on the host. Whether a package is installed is a question about
  `Arkbuild/var/lib/dpkg/status`, readable from outside without emulating
  anything.

Batching is the smaller change and gets nearly all of it, and it is upstream's
code rather than ours.

The saving is twice what the paragraph above assumed, because the lists are
walked a second time. After `cleanup_filesystem.sh` purges the build
dependencies it reinstalls what the finished system needs by reading the same
files again: `needed_packages32.txt` (27), `needed_packages.txt` (101) and
`bluetooth_needed_packages.txt` (17) — 145 entries, each with the same
`dpkg -s` plus `apt-mark manual` pair inside the chroot. Measured on the
2026-10-01 build, that one step ran from 00:12 to roughly 02:00 with nothing
to install: every package was already present. `kodi_needed_dev_packages.txt`
is skipped there, but only by accident of a chipset test that reads `*3566*`
and so never matches this board.

So the whole build pays the per-package emulation cost twice, in `build_deps.sh`
and again in `cleanup_filesystem.sh`. Batching both would return roughly two
and a half hours per build.

## Delete two cached failures before the next build

`make rg52mini` ends with an audit, and on 2026-10-01 it reported:

    EMPTY       /opt/ecwolf
    NO BINARY   /opt/gametank  (files present, no ELF among them)
    NO BINARY   /opt/hypseus-singe  (files present, no ELF among them)
    with binaries: 33   empty: 1   no executable: 2

Two of those are self-perpetuating. `Arkbuild_package_cache/rk3562/` holds
`ecwolfsa.tar.gz` at 130 bytes and `gametank.tar.gz` at 128 bytes — empty
tarballs written when the build failed, under keys that still match. Every
later build restores the failure instead of retrying it, which is why they are
missing from the 2026-09-29 image as well. Delete those two `.tar.gz` files
with their `.commit` partners and the next build will try again.

What it would then have to get past: `ecwolf-patch-002-add-exit-menu.patch`,
`gametank-patch-001-disable-joystick.patch` and
`hypseussinge-patch-0001-buildfix.patch` all failed to apply, and `libfuse2`
and `libpcap0.8` do not exist in trixie under those names.
