# Over-the-air updates (RG52 Mini)

From 1.1 on, dArkOS for the RG52 Mini updates itself over the network
(Options → Update), without rewriting the card. 1.0 and earlier have the
upstream updater, so moving from them to 1.1 means writing the card once.
The first package over the air is 1.1 → 1.2.

The upstream `Update.sh` is not used on this device. It fetches
christianhaitian/darkos-updates, whose packages are built for RK3326 and
RK3566 and pick files with "rk3566, else rk3326". On the RK3562 that would
install binaries for the RK3326. The 1.0 image carries the `.update*` flags up
to 08272026, so there it answers "no updates" until upstream publishes the
next one.

## Pieces

| | |
|---|---|
| `ota/make-ota.py` | builds a package from two release images (runs in the build host, as root) |
| `ota/rg52mini.json` | the feed the devices read; `{"response": []}` between releases |
| `ota/hooks/<version>[-name].sh` | scripts a release needs run after its files are in place |
| `ota/hooks/all-<name>.sh` | scripts every package runs, after the release's own (`all-fix-root-dir.sh`, `all-keep-quickmode.sh`, `all-ldconfig.sh`, `all-merge-dpkg.sh`) |
| `scripts/rk3562/darkos-ota` | the client, `/usr/local/sbin/darkos-ota` on the device |
| `dArkOS_Tools/rk3562/Update.sh` | Options → Update: the menu over the client |
| `scripts/rk3562/darkos-ota-boot.service` | marks an update as booted |
| `/etc/darkos-release` | `DEVICE`, `VERSION`, `BUILD_ID`, `BUILD_DATE`, written by `finishing_touches-rk3562.sh` |

## What a package is

It is a plain tar with these members:

- `manifest.json`;
- `payload.tar.zst`: the new and changed files, under `root/` (p4) and `boot/` (p3);
- `uboot.img`, if the boot loader changed;
- `hooks/`, and in `hooks/base/` the old build's copy of each file of the
  package database the update changes (see below).

A package updates exactly one build: `from_build_id` must equal `BUILD_ID` in
`/etc/darkos-release`. Each build gets a fresh `BUILD_ID` (UTC time of
`finishing_touches`, or `DARKOS_BUILD_ID` if set). Test builds between releases
work the same way as releases: build test1 and test2, then make a package from
test1 to test2.

Each entry in `files` carries:

- the sha256 the file had in the old build (`old_sha256`, `null` if new) and has in the new one;
- its type (`file`, `link`, `dir`);
- mode and owner.

`meta: true` means only the mode or owner changed. `delete` lists what the new
build no longer has.

Not in a package (see `ROOT_EXCLUDE` in `make-ota.py`):

- per-device state: ssh host keys, `/etc/shadow`, `machine-id`, `hostname`, Wi-Fi connections, `/var/lib/systemd`, bluetooth pairings;
- caches and logs;
- `/etc/ld.so.cache`, which is made from the libraries. On a device where
  it differs from the build's (anything installed with apt), the client
  would keep the old one as a file the user changed, and new libraries
  would be missing from it. `hooks/all-ldconfig.sh` in every package
  rebuilds it, and so does the client from 1.1 on;
- what firstboot consumes: `/roms.tar`, `/tempthemes`, everything under `/roms`;
- build leftovers in the image: `/meson`, `*/.git`, `/home/ark/pcsx2`, `/home/ark/sdl3`;
- `/boot` of the root filesystem, which p3 hides.

## How the client applies it

1. **Checks before touching anything:**
   - the device;
   - the build;
   - the battery (`min_battery`, default 20%, or the charger);
   - free space on `/` and on `/boot`;
   - no update half applied.
2. **Takes a read-only btrfs snapshot of `/`** (`/.ota-snapshot-<old build>`).
   Only the latest one is kept. Downloads live in a subvolume of their own
   (`/var/cache/darkos-ota/dl`), so the snapshot does not pin them.
3. **Unpacks the payload** into `/var/cache/darkos-ota/stage` and checks every
   file's sha256. On a mismatch the update stops there.
4. **Decides per file:**
   - the file is as in the old build → replace it;
   - it is already as in the new build → skip it;
   - it is under `etc/`, `home/`, `root/` or `var/lib/` and differs from both builds (the user changed it) → keep it, and put the new one beside it as `<name>.ota-new` (the package database is then merged by a hook, see below);
   - it is elsewhere and differs from both builds → overwrite it and log it (Quick Mode's scripts are then put back by a hook, see below).
5. **Copies aside the boot files** about to change (`/var/lib/darkos-ota/boot-backup`).
6. **Writes**, in this order:
   - the directories, then the root files;
   - then p3, last, so that an update cut short leaves the old kernel with a consistent root.

   Each file goes to a temporary name in the same directory and is renamed into place.
7. **Writes the boot loader,** if the package has one, the card is not
   dual-boot, and the partition named `uboot` on the card holds the boot loader
   of the old build. A loader installed by hand (`install-ddr928.sh`) is left
   alone and logged. The written loader is read back and compared.
8. **Runs the hooks** with `OTA_FROM`, `OTA_TO` and `OTA_DUALBOOT` in the environment.
9. **On any failure in steps 6–8,** puts everything back:
   - root files from the snapshot, with the ones a hook changed
     (`/var/lib/darkos-ota/merged`);
   - boot files from the copy;
   - the old boot loader;
   - new files removed.

`darkos-ota rollback` does the same later, from the booted new system. Options
→ Update offers it while the snapshot exists.

## The package database

`/var/lib/dpkg/status` differs from the build's on any device where something
was installed or removed with apt. By step 4 it would be kept, and dpkg would
not know the packages the update added: their files are there, `dpkg -l` does
not list them. Taking the new one instead would make dpkg forget the user's.

So `hooks/all-merge-dpkg.sh`, in every package and run last, merges it with
the old build's copy the package carries (`hooks/base/`, gzipped; the list is
`MERGE_BASE` in `make-ota.py`):

- **`dpkg/status`, apt's `extended_states`,** entry by entry (Package and
  Architecture): if the update changed an entry, the new build's wins, else the
  device's stays;
- **`dpkg/triggers/File`,** line by line, the same way;
- **files of `dpkg/info/` that both changed** (a package the user upgraded and
  the update changed too) take the new build's, as the entry did.

It runs only on what the client kept, removes the `.ota-new` files it used, and
logs what it merged. A failure leaves them as kept and does not fail the update.

## Quick Mode

Options → Advanced → Enable Quick Mode copies `pause.sh.qm` and `finish.sh.qm`
over `/usr/local/bin/pause.sh` and `finish.sh`, and replaces its own menu entry
with Disable Quick Mode. None of that is where step 4 keeps the user's
changes, so an update that brings new versions of these scripts would leave
Quick Mode half on. `hooks/all-keep-quickmode.sh`, in every package and run
first, does it again with the update's versions when `quickmode.sh` is there,
and lists what it changed for a rollback. What Quick Mode changes in `/etc`
and `/home` is kept by step 4 anyway.

State and log are in `/var/lib/darkos-ota/` (`state.json`, `ota.log`).

Commands:

- `darkos-ota version | check | local | update | install <pkg> | rollback | status | clean`;
- `--feed URL` overrides the feed, and so does a URL in `/home/ark/.config/darkos-ota-feed`. Use it for a test channel.

A package copied to `/roms/update/` (or `/roms/tools/update/`) is offered
before the network is asked.

There is no A/B copy of the system. If the system does not boot after an
update, the card has to be written again, as with GammaOS.

## Dual-boot card (dArkOS + GammaOS Next)

The card is recognised by `/boot/dualboot`. Its layout is in the
RG52mini-dualboot repository: p3 `darkos_boot`, p4 `rootfs`, p5–p11 GammaOS.
The numbers and GPT names are fixed for all versions of the card; the sizes
may change, so the client checks free space and assumes no sizes.

- **p1 (`uboot`):** the menu boot loader. GammaOS's own OTA writes it with
  every GammaOS release. dArkOS never writes it, and never writes p2
  `resource`.
- **Files of the dual-boot builder on p3:** `dualboot` and `bootmenu*_*.bmp`.
  They are never in a package (`BOOT_EXCLUDE`), and the client refuses to
  replace or delete them (`BOOT_PROTECTED`).
- **What the boot loader reads from p3 for every system,** not only dArkOS:
  - `extlinux/extlinux.conf` — without it the menu is off;
  - `logo.bmp` and `battery_*.bmp`;
  - **the device tree** `rk3562-rg52mini.dtb` — the loader's menu takes its
    keys and display from it.

  `make-ota.py` compares the nodes the menu uses between the two images:
  `play_joystick`, `adc-keys`, `saradc@ffaa0000`, `dsi@ffb10000`, `panel@0`
  and `backlight`. It refuses the package if they differ, unless
  `--allow-dtb-change` after the menu was checked on a dual-boot card.
  Phandle numbers are ignored in the comparison; the pinctrl groups
  `play_joystick` points to are not compared, so a change of key pins needs
  the same manual check.
- **Do not touch:**
  - the partition table and the bootable flag (only p3 has `legacy_boot`; two bootable partitions broke the loader);
  - GammaOS's partitions;
  - the vendor storage of the card (sector 7168 on), where the loader keeps the menu choice.

## Release procedure

1. Build the release image; `VERSION` in the tree is its number.
2. `sudo ota/make-ota.py <previous release>.img <new>.img -o <dir>
   --url-base https://github.com/mamaich/dArkOS_rg52mini/releases/download/v<new>
   --feed ota/rg52mini.json`.
   This prints the package and its sha256 and adds the entry to the feed.
   Packages from older releases straight to the new one can be made the same
   way; the client picks the newest entry for its build.
3. Upload the package as an asset of the release, next to the image volumes.
4. Only then commit and push `ota/rg52mini.json`; devices see the update from
   that moment.
5. Bump `VERSION` for the next release.

Comparing two images takes about three minutes. Between 10072026 and 10082026
the difference was 99 changed files of 295 MiB and 39 deletions on the root,
and 4 files of 42 MiB on p3. The boot loader was the same.
