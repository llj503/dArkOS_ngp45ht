#!/bin/bash
# In-place libretro core updater for the NGP45HT card.
#
# dArkOS has no on-device updater: build_retroarch.sh:98 wgets each core as a zip
# from christianhaitian/retroarch-cores at image build time, so the card carries
# whatever that branch held on 2026-06-23.  This script repeats that step against
# the running install, and keeps the previous .so so a bad core is one command
# away from being undone.
#
#   ngp-core-update.sh plan              list installed cores the branch rebuilt later
#   ngp-core-update.sh check [a b ...]   also download and compare bytes (all if none named)
#   ngp-core-update.sh install [a b ...] back up, replace, refresh the .info
#   ngp-core-update.sh rollback [a b ...] restore the newest backup
#   ngp-core-update.sh verify             dlopen every core and report failures (advisory: RetroArch
#                                         provides symbols a bare dlopen cannot see, so it false-fails)
#   ngp-core-update.sh compare            same probe on the backups, only the differences (advisory)
#   ngp-core-update.sh raload <core...>   authoritative: RetroArch itself opens each core
#   ngp-core-update.sh --32 ...          same against the armhf core dir
#
# Runs as ark: cores live under /home/ark, backups under /roms (31 GB free, the
# rootfs only has 5.8 GB and mame alone is 200 MB).  No sudo anywhere.
set -u

BRANCHES="rg503 master"                # rg503 is what dArkOS pulls for non-rk3326 boards
IMAGE_DATE="2026-06-23"                # base image build; later dates are real upgrades
IMAGE_INT=20260623
BASE="https://raw.githubusercontent.com/christianhaitian/retroarch-cores"
INFOBASE="https://raw.githubusercontent.com/libretro/libretro-core-info/master"
BACKUPROOT="/roms/core-backups"
CACHE="$HOME/.cache/ngp-cores"

BITS=64
ARCHDIR="aarch64"
# COREDIR is overridable so `verify` can be run against a backup dir for a before/after diff.
COREDIR="${COREDIR:-/home/ark/.config/retroarch/cores}"
if [ "${1:-}" = "--32" ]; then
    BITS=32; ARCHDIR="arm7hf"; COREDIR="/home/ark/.config/retroarch32/cores"
    shift
fi
# SOURCE=buildbot pulls the official nightlies (231 aarch64 cores incl hbmame);
# SOURCE=darkos keeps the old rg503/master behaviour.
SOURCE="${SOURCE:-buildbot}"
BBROOT="https://buildbot.libretro.com/nightly"
if [ "$SOURCE" = "buildbot" ]; then
    BRANCHES="latest"
    BBARCH=$([ "$BITS" = 32 ] && echo armhf || echo aarch64)
else
    BBARCH=""
fi

idx_url() { if [ "$SOURCE" = buildbot ]; then echo "$BBROOT/linux/$BBARCH/latest/.index-extended"; else echo "$BASE/$1/$ARCHDIR/.index-extended"; fi; }
so_url()  { if [ "$SOURCE" = buildbot ]; then echo "$BBROOT/linux/$BBARCH/latest/$2_libretro.so.zip";   else echo "$BASE/$1/$ARCHDIR/$2_libretro.so.zip";   fi; }

BACKUP="$BACKUPROOT/$(date +%Y%m%d)-$BITS-$SOURCE"
mkdir -p "$CACHE" "$BACKUP"

# curl on the card pulls at 6 MB/s where a PC behind the same NAT gets ~11 KB/s,
# so everything here is fetched locally.
CURL="curl -fsSL --retry 3 --retry-delay 2 --max-time 120"

fetch_index() {                        # branch -> $CACHE/$SOURCE.$branch.$ARCHDIR
    local b=$1 f="$CACHE/$SOURCE.$1.$ARCHDIR"
    [ -s "$f" ] || $CURL "$(idx_url "$b")" -o "$f" || { rm -f "$f"; echo "index fetch failed: $(idx_url "$b")" >&2; }
}

newest() {                             # prints "<branch> <date> <srcsha>" for $1, empty if unpublished
    local core=$1 b best="" bdate="" bsha=""
    for b in $BRANCHES; do
        local line=$(grep -E "^[0-9-]+ +[0-9a-f]+ +${core}_libretro\.so\.zip$" "$CACHE/$SOURCE.$b.$ARCHDIR" 2>/dev/null | head -1)
        [ -z "$line" ] && continue
        local d=${line%% *} s=${line#* }; s=${s%% *}
        if [ -z "$best" ] || [ "$d" \> "$bdate" ]; then best=$b; bdate=$d; bsha=$s; fi
    done
    [ -n "$best" ] && echo "$best $bdate $bsha"
}

installed_names() {
    ls "$COREDIR"/*.so 2>/dev/null | sed "s#.*/##; s#_libretro\.so\$##"
}

download_so() {                        # $1=branch $2=core -> echoes path
    local out="$CACHE/$SOURCE.$1.$2_libretro.so"
    if [ ! -s "$out" ]; then
        $CURL "$(so_url "$1" "$2")" -o "$out.zip" || { echo ""; return 1; }
        unzip -p "$out.zip" > "$out" || { rm -f "$out" "$out.zip"; echo ""; return 1; }
        rm -f "$out.zip"
        # a core is an ELF shared object; anything else means we were served a page
        head -c 4 "$out" | grep -q $'ELF' || { echo "NOTELF $2"; rm -f "$out"; return 1; }
    fi
    echo "$out"
}

probe() {                              # echoes "ok" or "rc=<n> <first line of the error>"
    local out rc
    out=$(python3 -c '
import ctypes, sys
try:
    h = ctypes.CDLL(sys.argv[1])
    missing = [s for s in ("retro_run", "retro_get_system_info") if not hasattr(h, s)]
    if missing:
        sys.exit("no " + ",".join(missing))
except OSError as e:
    sys.exit(str(e).splitlines()[0][:120])
' "$1" 2>&1)
    rc=$?
    [ $rc -eq 0 ] && { echo ok; return; }
    # strip the directory so compare() does not report the backup path as a change
    out=${out##*/}
    echo "rc=$rc ${out:-crashed without a python error}"
}

ra_setup() {
    RA_BIN=$(command -v retroarch || echo /opt/retroarch/bin/retroarch)
    [ -x "$RA_BIN" ] || { RA_BIN=""; return; }
    mkdir -p /tmp/rahome
    printf '%s\n' 'video_driver = "null"' 'audio_driver = "null"' 'input_driver = "null"' \
      'input_joypad_driver = "null"' 'menu_enable = "false"' 'save_config_on_exit = "disabled"' \
      > /tmp/rahome/null.cfg
}

# RetroArch opens cores with RTLD_LAZY inside a process that already provides
# libstdc++, libiconv and friends, so it is the only honest loader test: a bare
# ctypes dlopen reported DoubleCherryGB as broken while RetroArch loads it fine,
# and it also cannot see fake08's old build crash (SIGILL) as clearly.
ra_probe() {
    local log
    [ -n "$RA_BIN" ] || return 0
    log=$(HOME=/tmp/rahome timeout 40 "$RA_BIN" -v -L "$1" --config /tmp/rahome/null.cfg 2>&1)
    if echo "$log" | grep -q "Failed to open libretro core"; then return 1; fi
    return 0
}

cmd=${1:-plan}
shift 2>/dev/null || true
cores="$*"
[ -n "$cores" ] || cores=$(installed_names)

case $cmd in
plan)
    for b in $BRANCHES; do fetch_index $b; done
    printf "%-26s %-8s %-11s %s\n" CORE BRANCH BUILT SRC
    newer=0; same=0; unpublished=""
    for c in $(installed_names); do
        n=$(newest $c)
        if [ -z "$n" ]; then unpublished="$unpublished $c"; continue; fi
        set -- $n
        di=${2//-/}
        if [ "$di" -gt "$IMAGE_INT" ]; then
            printf "%-26s %-8s %-11s %s\n" "$c" "$1" "$2" "${3:0:8}"; newer=$((newer+1))
        else
            same=$((same+1))
        fi
    done
    echo "--- $newer rebuilt after $IMAGE_DATE, $same already current"
    [ -n "$unpublished" ] && echo "--- published in neither branch (cannot refresh):$unpublished"
    ;;
check)
    for b in $BRANCHES; do fetch_index $b; done
    diffcount=0; samecount=0
    for c in $cores; do
        n=$(newest $c); [ -z "$n" ] && { printf "%-26s not published, kept as is\n" "$c"; continue; }
        set -- $n; branch=$1; date=$2
        cur=$(md5sum "$COREDIR/${c}_libretro.so" 2>/dev/null | cut -d' ' -f1)
        so=$(download_so "$branch" "$c")
        if [ -z "$so" ]; then printf "%-26s DOWNLOAD FAILED (%s)\n" "$c" "$branch"; continue; fi
        new=$(md5sum "$so" | cut -d' ' -f1)
        sz=$(( $(stat -c%s "$so") / 1000000 ))
        if [ "$new" = "$cur" ]; then
            printf "%-26s %s %s  %4d MB  same bytes as the card\n" "$c" "$branch" "$date" "$sz"
            samecount=$((samecount+1))
        else
            printf "%-26s %s %s  %4d MB  DIFFERS (card %s -> %s)\n" "$c" "$branch" "$date" "$sz" "${cur:0:8}" "${new:0:8}"
            diffcount=$((diffcount+1))
        fi
    done
    echo "--- $diffcount differ, $samecount identical"
    ;;
install)
    for b in $BRANCHES; do fetch_index $b; done
    ra_setup
    installed=0; skipped=0; reverted=0
    for c in $cores; do
        n=$(newest $c); [ -z "$n" ] && { printf "%-26s not published\n" "$c"; skipped=$((skipped+1)); continue; }
        set -- $n; branch=$1; date=$2
        cur=$(md5sum "$COREDIR/${c}_libretro.so" 2>/dev/null | cut -d' ' -f1)
        so=$(download_so "$branch" "$c")
        [ -z "$so" ] && { printf "%-26s download failed\n" "$c"; skipped=$((skipped+1)); continue; }
        new=$(md5sum "$so" | cut -d' ' -f1)
        if [ "$new" = "$cur" ]; then printf "%-26s already current (%s %s)\n" "$c" "$branch" "$date"; skipped=$((skipped+1)); continue; fi
        [ -n "$cur" ] && cp -a "$COREDIR/${c}_libretro.so" "$BACKUP/" 2>/dev/null
        # never leave a half-written core where RetroArch will find it
        cp "$so" "$COREDIR/${c}_libretro.so.new" && chmod 755 "$COREDIR/${c}_libretro.so.new" \
            && mv "$COREDIR/${c}_libretro.so.new" "$COREDIR/${c}_libretro.so" || { printf "%-26s INSTALL FAILED\n" "$c"; continue; }
        $CURL "$INFOBASE/${c}_libretro.info" -o "$COREDIR/${c}_libretro.info.new" \
            && [ -s "$COREDIR/${c}_libretro.info.new" ] && mv "$COREDIR/${c}_libretro.info.new" "$COREDIR/${c}_libretro.info" \
            || rm -f "$COREDIR/${c}_libretro.info.new"
        got=$(md5sum "$COREDIR/${c}_libretro.so" | cut -d' ' -f1)
        if [ "$got" != "$new" ]; then printf "%-26s MD5 MISMATCH after install (%s)\n" "$c" "${got:0:8}"; continue; fi
        if ! ra_probe "$COREDIR/${c}_libretro.so"; then
            # the build is newer but this rootfs cannot open it (np2kai rev. later than 22 needs
            # ymzadpcm_getpcm that the older build had statically linked) -- do not leave it installed
            if [ -f "$BACKUP/${c}_libretro.so" ]; then
                cp -a "$BACKUP/${c}_libretro.so" "$COREDIR/${c}_libretro.so"
                printf "%-26s %s %s but RetroArch cannot open it -- reverted\n" "$c" "$branch" "$date"
            else
                printf "%-26s RetroArch cannot open it and there was no backup -- LEFT INSTALLED\n" "$c"
            fi
            reverted=$((reverted+1)); continue
        fi
        printf "%-26s installed %s %s  verified + RetroArch opens it\n" "$c" "$branch" "$date"
        installed=$((installed+1))
    done
    echo "--- $installed replaced and load-tested, $reverted reverted, $skipped unchanged; backups in $BACKUP"
    echo "--- restart RetroArch or ES to load them; undo one with: ngp-core-update.sh rollback <core>"
    ;;
verify)
    # One process per core: a core built for a newer armv8 revision dies with
    # SIGILL (rc=132) instead of taking the whole sweep down.
    ok=0; bad=0
    for f in "$COREDIR"/*_libretro.so; do
        r=$(probe "$f")
        if [ "$r" = ok ]; then ok=$((ok+1)); else bad=$((bad+1)); printf "  FAIL %-30s %s\n" "$(basename $f)" "$r"; fi
    done
    echo "--- dlopen: $ok ok, $bad failed"
    ;;
compare)
    # The failures that matter are only the ones we caused: run the same probe on
    # every backup and report cores whose result changed.
    src=$(ls -1d $BACKUPROOT/*-$BITS 2>/dev/null | tail -1)
    [ -n "$src" ] || { echo "no backup dir under $BACKUPROOT"; exit 1; }
    echo "comparing current cores against $src"
    changed=0; same=0
    for old in "$src"/*_libretro.so; do
        n=$(basename "$old"); cur="$COREDIR/$n"
        [ -f "$cur" ] || continue
        o=$(probe "$old"); c=$(probe "$cur")
        if [ "$o" != "$c" ]; then changed=$((changed+1)); printf "  CHANGED %-28s old=[%s] new=[%s]\n" "$n" "$o" "$c";
        else same=$((same+1)); fi
    done
    echo "--- $changed behave differently, $same unchanged"
    ;;
raload)
    # The check that actually matters: let RetroArch itself dlopen each core in a
    # throwaway HOME with null video/audio/input, so the card's real config and
    # the panel's DRM master are untouched. A core that initializes prints its own
    # banner; "requires content, but nothing was provided" is the success line.
    ra_setup
    [ -n "$RA_BIN" ] || { echo "no retroarch binary found"; exit 1; }
    ok=0; bad=0
    for c in $cores; do
        f="$COREDIR/${c}_libretro.so"
        [ -f "$f" ] || { printf "  SKIP  %-24s not installed\n" "$c"; continue; }
        log=$(HOME=/tmp/rahome timeout 40 "$RA_BIN" -v -L "$f" --config /tmp/rahome/null.cfg 2>&1)
        banner=$(echo "$log" | grep -a '\[libretro' | head -1 | sed 's/.*\[libretro[^]]*\] //')
        if echo "$log" | grep -qiE 'Failed to (dlopen|load libretro core)|has no global symbol|Segmentation fault'; then
            bad=$((bad+1)); printf "  FAIL  %-24s %s\n" "$c" "$(echo "$log" | grep -aiE 'fail|segmentation' | head -1)"
        else
            ok=$((ok+1)); printf "  ok    %-24s %s\n" "$c" "${banner:-(loaded, no banner)}"
        fi
    done
    echo "--- RetroArch loaded $ok cores, $bad failed"
    ;;
rollback)
    for c in $cores; do
        src=$(ls -1d $BACKUPROOT/*-$BITS 2>/dev/null | tail -1)
        f="$src/${c}_libretro.so"
        if [ -n "$src" ] && [ -f "$f" ]; then
            cp -a "$f" "$COREDIR/${c}_libretro.so" && printf "%-26s restored from %s\n" "$c" "$src"
        else
            printf "%-26s no backup found\n" "$c"
        fi
    done
    ;;
*)
    sed -n '3,20p' "$0"; exit 1;;
esac
