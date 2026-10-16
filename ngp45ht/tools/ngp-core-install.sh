#!/bin/bash
# Install a single libretro core onto this NGP45HT card, verified before it lands.
#
# Why this exists: dArkOS's core repo (raw.githubusercontent christianhaitian/retroarch-cores,
# branches rg503/master) carries only ~170 aarch64 cores and is what RetroArch's own
# "Core Updater" points at, so cores that only exist on the official buildbot -- hbmame
# for example -- can never be fetched from inside RA. RA's updater also overwrites without
# backup or verification, which is how a bad build silently kills a core.
#
#   ./ngp-core-install.sh hbmame                     # buildbot, 64-bit
#   ./ngp-core-install.sh --source rg503 gambatte
#   ./ngp-core-install.sh --arch 32 somecore         # buildbot armhf (note: fewer cores)
#   ./ngp-core-install.sh --list-only hbmame
#
# Verification: load the core in RetroArch with null drivers in a throwaway HOME. A core
# that loads either prints "requires content" and exits, or is still running when the
# timeout fires. Anything else (dlopen failure, undefined symbol, SIGILL=132, SIGSEGV=139)
# aborts the install.

SRC=buildbot
ARCH=64
CORE=""
VERIFY_ONLY_TIMEOUT=25
BB64=https://buildbot.libretro.com/nightly/linux/aarch64/latest
BB32=https://buildbot.libretro.com/nightly/linux/armhf/latest
RG=https://raw.githubusercontent.com/christianhaitian/retroarch-cores

while [ $# -gt 0 ]; do
  case "$1" in
    --source) SRC="$2"; shift 2 ;;
    --arch)   ARCH="$2"; shift 2 ;;
    --list-only) LIST=1; shift ;;
    -*) echo "unknown flag $1"; exit 1 ;;
    *)  CORE="$1"; shift ;;
  esac
done
[ -n "$CORE" ] || { sed -n '2,20p' "$0"; exit 1; }

if [ "$ARCH" = "32" ]; then
  DIRS="armv7-neon-hf armhf"
  RA=/opt/retroarch/bin/retroarch32
  case "$SRC" in
    buildbot) URL="$BB32/${CORE}_libretro.so.zip" ;;
    rg503|master) URL="$RG/$SRC/arm7hf/${CORE}_libretro.so.zip" ;;
    *) echo "bad source"; exit 1 ;;
  esac
  CD=/home/ark/.config/retroarch32/cores
else
  RA=/opt/retroarch/bin/retroarch
  case "$SRC" in
    buildbot) URL="$BB64/${CORE}_libretro.so.zip" ;;
    rg503|master) URL="$RG/$SRC/aarch64/${CORE}_libretro.so.zip" ;;
    *) echo "bad source"; exit 1 ;;
  esac
  CD=/home/ark/.config/retroarch/cores
fi

echo "== resolve =="
code=$(curl -sIL --max-time 25 -o /dev/null -w "%{http_code}" "$URL")
printf "  %-14s %s\n  http=%s\n" "$CORE" "$URL" "$code"
if [ -n "$LIST" ]; then
  # which platforms actually carry it?
  for u in "$BB64" "$BB32" "$RG/rg503/aarch64" "$RG/rg503/arm7hf" "$RG/master/aarch64"; do
    printf "  %-40s %s\n" "$u" "$(curl -s --max-time 20 "$u/.index-extended" | grep -ac "${CORE}_libretro.so.zip")"
  done
  exit 0
fi
[ "$code" = "200" ] || { echo "not available from $SRC (http=$code)"; exit 1; }

T=/tmp/ngp-core-$CORE
rm -rf "$T"; mkdir -p "$T"
echo "== download =="
curl -sL --fail --max-time 180 -o "$T/core.zip" "$URL" || { echo "download failed"; exit 1; }
python3 -c "
import zipfile; z=zipfile.ZipFile('$T/core.zip'); z.extractall('$T'); print('  members:', z.namelist())"
SO=$(find "$T" -name "*.so" | head -1)
[ -n "$SO" ] || { echo "no .so in archive"; exit 1; }
ls -l "$SO" | sed 's/^/  /'

echo "== verify by loading it in RetroArch =="
mkdir -p /tmp/rahome-verify/.config/retroarch
cat > /tmp/rahome-verify/.config/retroarch/retroarch.cfg <<'CFG'
video_driver = "null"
audio_driver = "null"
input_driver = "null"
menu_driver = "null"
rgui_show_start_screen = "false"
save_config_on_exit = "disabled"
CFG
HOME=/tmp/rahome-verify timeout $VERIFY_ONLY_TIMEOUT "$RA" -L "$SO" > "$T/verify.log" 2>&1
rc=$?
echo "  retroarch rc=$rc"
if grep -aqE "Failed to dlopen|symbol lookup error|undefined symbol|Illegal instruction|Segmentation fault" "$T/verify.log"; then
  echo "  VERIFY FAILED, refusing to install:"; grep -aE "dlopen|symbol|undefined|Illegal|Segmentation" "$T/verify.log" | head -5 | sed 's/^/    /'; exit 1
fi
if [ "$rc" -eq 132 ] || [ "$rc" -eq 139 ] || [ "$rc" -eq 1 ]; then
  echo "  VERIFY FAILED (rc=$rc), refusing to install"; tail -6 "$T/verify.log" | sed 's/^/    /'; exit 1
fi
[ "$rc" -eq 124 ] && echo "  still running at timeout -> core loaded (MAME-family behaviour)" || echo "  exited cleanly -> core loaded"

echo "== generate .info from the core itself =="
python3 - "$SO" "$CORE" <<'PY'
import ctypes, struct, sys
so, core = sys.argv[1], sys.argv[2]
lib = ctypes.CDLL(so, mode=ctypes.RTLD_GLOBAL)
def s(p): return ctypes.cast(p, ctypes.c_char_p).value.decode("utf-8", "replace") if p else ""
buf = ctypes.create_string_buffer(8 * 8)
lib.retro_get_system_info(ctypes.byref(buf))
f = [struct.unpack("Q", buf[i * 8:(i + 1) * 8])[0] for i in range(6)]
name, ver, exts = s(f[0]), s(f[1]), s(f[2])
flags = struct.unpack("Q", buf[4 * 8:5 * 8])[0]
emu = evar = ""
try:
    e = ctypes.create_string_buffer(8 * 4)
    lib.retro_get_emulator_info(ctypes.byref(e))
    g = [struct.unpack("Q", e[i * 8:(i + 1) * 8])[0] for i in range(4)]
    emu, evar = s(g[0]), s(g[1])
except Exception:
    pass
# library_name is often generic ("MAME"), so keep the requested core name visible
disp = emu or ("%s (%s)" % (name, core) if name and name.lower() != core.lower() else (name or core))
cat = "Arcade" if "mame" in (name + emu + core).lower() else "Unknown"
open("/tmp/ngp-core-%s/%s_libretro.info" % (core, core), "w").write(
'''display_name = "%s"
manufacturer = "%s"
category = "%s"
supported_system_extensions = "%s"
supported_extensions = "%s"
corename = "%s"
licence = "See the core's own license"
display_version = "%s"
description = "%s (%s)"
''' % (disp, emu or name or core, cat, exts or "zip|7z", exts or "zip|7z", core,
       evar or ver, emu or name or core, evar or ver))
print("  name=%s ver=%s exts=%s needs_bios=%s" % (name, ver, exts, bool((flags >> 1) & 1)))
PY
INFO="$T/${CORE}_libretro.info"
[ -s "$INFO" ] || { echo "info generation failed"; exit 1; }
cat "$INFO" | sed 's/^/  /'

echo "== install (old copies backed up first) =="
BK="/roms/core-backups/$(date +%Y%m%d)-$([ "$ARCH" = 32 ] && echo 32 || echo 64)"
mkdir -p "$BK"
for f in "$CD/${CORE}_libretro.so" "$CD/${CORE}_libretro.info"; do
  [ -e "$f" ] && mv "$f" "$BK/" && echo "  backed up $(basename "$f") -> $BK"
done
install -o ark -g ark -m 644 "$SO" "$CD/${CORE}_libretro.so"
install -o ark -g ark -m 644 "$INFO" "$CD/${CORE}_libretro.info"
printf "  installed into %s (so=%s info=%s)\n" "$CD" "$(ls "$CD"/*.so | wc -l)" "$(ls "$CD"/*.info | wc -l)"
df -h / | tail -1 | sed 's/^/  /'
rm -rf "$T"
echo "done. In RetroArch: Load Core -> ${CORE} (restart ES/RA if the list looks stale)."
