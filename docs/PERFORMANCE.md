# Performance

Four Cortex-A53 at 2.0 GHz and 2 GB of RAM in a case with no heatsink. Two
things actually limit emulation here — the thermal budget and memory pressure —
and everything below is sorted by whether it was measured, shipped, or merely
sounds good.

## What the device does under load

Measured on the Android port of the same hardware, which shares the SoC, the
case and the power tree:

    GPU  at 6/6 (the lowest of six DVFS steps) within seconds of a 3D load
    CPU  throttled by the same thermal zone
    skin temperature climbs until the trip points act, then stays there

The important part is that the GPU sits at the *bottom* step, not somewhere in
the middle. That rules out a whole family of explanations.

### Power-budget weights do not help — tested

The `power_allocator` governor divides the sustainable power budget between
cooling devices according to `contribution` in the device tree, exposed as
`cdev0_weight`/`cdev1_weight`. The obvious idea is to give the GPU more of the
budget and the CPU less.

It was tested at 8:1 — GPU 2048 against CPU 256 — and changed nothing. The GPU
stayed at 6/6.

Why: the constraint is not how the budget is split, it is the ceiling itself.
When the zone is above its target, the allocator shrinks *every* device's
allocation; the weights only decide the proportions of something that is
already too small. A bigger slice of a budget that is one sixth of what the GPU
wants is still the bottom DVFS step.

Do not re-litigate this one. It is written up in the Android port's
`docs/09-hardware-notes.md` under "what did not help".

### `sustainable-power`

`sustainable-power` in the thermal zone tells the allocator how many milliwatts
the device can dissipate indefinitely. It is a *description* of the hardware,
not a limit — raising it does not make the device cooler, it makes the governor
believe there is more headroom than there is, so it throttles later and less.

If the number is genuinely too low the result is a device that runs cool and
slow for no reason, and raising it is free performance. If it is right,
raising it means the die runs hotter, the trip points act harder when they
finally do, and the outcome is oscillation instead of a steady state — plus
whatever a permanently hotter part does to its lifetime and to the case
temperature in someone's hands.

Not changed. Without a thermocouple on the case there is no way to tell which
of those two situations this is, and the failure mode of guessing wrong is a
device that gets hot in the hand.

Raising `trip-point-1` has the same shape and the same objection. A heatsink or
a thermal pad against the shield can is the honest fix, and it moves the real
constraint instead of the reported one.

## Shipped

### Two-tier swap

2 GB of RAM with no swap at all was the previous state. Now:

| tier | size | priority | where |
|---|---|---|---|
| zram | 1536 MB | 100 | RAM, compressed |
| eMMC | 256 MB | 10 | `swap` partition |

zram fills first because its priority is higher; the eMMC partition only takes
what zram rejects — pages that do not compress, and pages cold enough to have
been written back. On Android on this device zram was clearly worth having, and
that is what prompted it.

`lzo-rle` is the compressor (`ALGO_PREF="lzo-rle lz4 zstd lzo"`, walked against
what `comp_algorithm` actually offers). Speed is the scarce resource on four
A53s: zram only pays if compressing costs less than the fault it avoids.
lzo-rle has been the kernel's own default since 5.1 for that reason. `lz4` was
added to the kernel (`CONFIG_CRYPTO_LZ4=y`) so the list has somewhere to fall.
Put `zstd` first instead if RAM turns out tighter than CPU — it compresses
appreciably better and would keep the eMMC tier idle longer.

Writing a name the kernel does not have fails *silently* and leaves the default
in place, which is how the first build ended up on lzo-rle by accident rather
than by choice. The script now reports which one it got.

eMMC wear was the concern, and the tuning answers it:

* `vm.swappiness=100` — sounds aggressive, is the opposite. It biases reclaim
  towards anonymous pages (zram, cheap) instead of file pages (re-read from
  eMMC). Low swappiness on a zram system means *more* eMMC traffic, not less.
* `vm.page-cluster=0` — one page per fault instead of eight. Readahead is
  pointless against RAM.
* The eMMC tier is last-resort by construction: priority 10 against 100.

The partition is found by GPT label, never hardcoded, and
`/usr/local/sbin/emmc-swap` refuses to touch it unless all four hold: the label
is `swap`, `blkid` says the type is already `swap`, the size is between 64 MB
and 2 GB, and nothing has it mounted. It waits up to 30 s for
`/dev/disk/by-partlabel/swap` to appear, because udev and the service race.
It never runs `mkswap` on a partition it did not already recognise as swap —
`mkswap` on the wrong device is unrecoverable.

`CONFIG_ZRAM_WRITEBACK=y` is in the kernel but not wired up. It is the other
way to spend the eMMC partition: instead of a second swap device, zram evicts
its own idle or incompressible pages to a backing block device. Cleaner in
principle — one swap device, the kernel decides — but it needs a writeback
device configured and an idle-marking policy, and the priority approach already
works and is trivially observable in `/proc/swaps`.

### Kernel modules stripped

`--strip-debug` on every `.ko` in `finishing_touches`: 100 MB → 6.3 MB. Not a
speed change, but it is 94 MB of an SD card and of every image download.

Never plain `strip` on a module — it removes the symbols `MODVERSIONS` CRCs are
computed against and the module stops loading.

### The kernel itself, not just its modules

`Image` went from 39,164,416 bytes in v09162026 to 32,965,120 in v09292026,
6.0 MB smaller, in two steps and for two different reasons.

The first, about 4.9 MB, was debugging the device never reads. `FUNCTION_TRACER`
alone was 473,376 bytes of `__start_mcount_loc` — 59,172 trace points, each of
which costs a 24-byte `dyn_ftrace` record at boot, about 1.4 MB of RAM, plus
the `-pg` prologue padding left in `.text` for good. `DYNAMIC_DEBUG` was
356,384 bytes of descriptors. Also off: `SLUB_DEBUG`, `SCHED_DEBUG`,
`IKCONFIG`, and the debugging inside the drivers that do run — `ROCKCHIP_DEBUG`,
`ROCKCHIP_DRM_DEBUG`, `ROCKCHIP_RGA_DEBUGGER`, `RK_DMABUF_DEBUG`,
`SW_SYNC_DEBUG`, `BT_DEBUGFS`, `USB_GADGET_DEBUG_FILES`, `PM_DEBUG`,
`DEBUG_DEVRES`, `BLK_DEV_IO_TRACE`, `RCU_TRACE`.

The second, 1.1 MB, was the two GPU drivers that cannot bind on this hardware —
see HARDWARE.md.

Deliberately kept: `KALLSYMS`, because panic reports now go to pstore and are
worth reading by name (`KALLSYMS_ALL` was already off); the hang detectors; and
`DEBUG_FS`, which turned out to need asking for explicitly — `BLK_DEV_IO_TRACE`
was the only thing selecting it, and `scripts/rk3562/ledctl.sh` drives the power
LED through `/sys/kernel/debug/regulator/vcc-led/enable`. Switching off
blktrace would have taken the LED with it. See BUILDING.md for how to catch
that class of mistake before it reaches an image.

### Cortex-A53 build flags

See KNOWN-ISSUES: sixteen core-build scripts targeted Cortex-A55, and the Amiga
emulator was built for ARMv8.2-A on an ARMv8.0-A part. `-mtune` was only
costing scheduling; the `-mcpu` was potentially fatal.

### PPSSPP without hardening

`-fno-stack-protector -U_FORTIFY_SOURCE` for PPSSPPSDL only, on the two
`-DCMAKE_{C,CXX}_FLAGS` arguments in `rk3562_core_builds/scripts/ppsspp.sh`.

They started out exported as `CFLAGS`/`CXXFLAGS` from `build_ppssppsa.sh`,
which did nothing at all: cmake reads those environment variables only when
`CMAKE_C_FLAGS`/`CMAKE_CXX_FLAGS` are unset, and that script sets both
explicitly. Nothing failed, nothing was logged — the build just quietly kept
the hardening. It was caught by reading `flags.make` out of a running build,
which is the way to check this kind of change:

    build/CMakeFiles/PPSSPPSDL.dir/flags.make

The reasoning is narrow and does not generalise: this device runs only software
from this image and never downloads executables, and PPSSPP's inner loops are
the kind of small hot functions where a canary per call is measurable. It has
not been benchmarked. If someone does measure it and the difference is noise,
take it back out — the flags exist for a reason.

## Two emulators were built with no optimisation at all

Worth more than everything else on this page put together, and it was found by
accident while wondering why one Dreamcast game was slow.

**flycast** asked cmake for `CMAKE_BUILD_TYPE=Release` and then set
`CMAKE_C_FLAGS_RELEASE` and `CMAKE_CXX_FLAGS_RELEASE` to `-DNDEBUG`. Those
variables *replace* what the build type carries rather than adding to it, and
cmake's Release is `-O3 -DNDEBUG` — so the `-O3` was thrown away and gcc fell
back to its default, `-O0`. The build log has `CMAKE_VERBOSE_MAKEFILE` on and
settles it: of 389 compile lines under `flycast-build`, exactly one carries an
optimisation flag. The SH4 memory handlers and the MMU translation, which are
the hot path for anything demanding, were all built unoptimised.

**fake-08** was the second one an audit of the same log found: 57 compiles, no
`-O` among them. That one is upstream's doing — the recipe builds the
`SDL2Desktop` target, whose makefile says `-g -Wall` and nothing more, because
it is the target meant for debugging on a PC. Every handheld target that
project ships — miyoomini, funkey-s, gcw0, bittboy — uses `-Ofast`.

Both fixed in `mamaich/rk3566_core_builds` (`ae544e5`, `6aaaa37`), which also
applies the `-march=armv8-a+crc -mtune=cortex-a53` correction from `7290d75`.

**Both are in v09292026**, and it was verified rather than assumed: with the
build running, `flags.make` under the PPSSPP build directory read

    -Ofast -fno-tree-slp-vectorize -D_NDEBUG -march=armv8-a+crc
    -mtune=cortex-a53 -ftree-vectorize -funsafe-math-optimizations
    -fno-stack-protector -U_FORTIFY_SOURCE -O3 -DNDEBUG

— the `-Ofast`, the correct `-mtune`, and the `-O3` that the build type carries
once nothing replaces it. The cache did not undo it either: with the key now
including the recipe hash, PPSSPP rebuilt from source instead of restoring the
artifact built under the old flags.

How to check this for any component, since nothing reports it:

    grep -c 'cc1plus\|cc1' build.log          # compile lines
    grep 'cc1plus\|cc1' build.log | grep -c '\-O[0-3sfast]'

A component whose second number is near zero is being built for debugging.

## Not worth doing

* **LSE atomics** (`CONFIG_ARM64_LSE_ATOMICS`). ARMv8.1 feature, this is an
  ARMv8.0 part. The kernel compiles both paths and picks at run time via
  alternatives, so enabling it costs a few kilobytes and does nothing here.
* **Disabling `hardened_usercopy` and friends kernel-wide.** Plausible on
  paper, and the same "only runs its own software" argument applies, but these
  guards sit on syscall paths rather than in emulator inner loops, and nothing
  here has been measured. Do the measurement before the change.
* **Newer GCC / LLVM, `-O3`, PGO.** Everything is built with the Debian
  toolchain in the chroot. Rebuilding one emulator against a newer compiler and
  timing it on the device is a real experiment with a real answer; swapping the
  toolchain for the whole image on the assumption that newer is faster is not.

## If you want to measure

Start on the device, not in the build. The whole budget question is settled by
a few files:

    /sys/class/thermal/thermal_zone0/temp
    /sys/class/devfreq/fde60000.gpu/cur_freq
    /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
    /proc/swaps
    /sys/block/zram0/mm_stat

A run that starts fast and settles slower is thermal. One that stutters with
`pswpin` climbing is memory. They want opposite fixes, and the sysfs files say
which one you have in about a minute.
