#!/bin/bash
# ngp-shaders.sh -- install the ROCKNIX-style shader/overlay packs onto dArkOS
# for the NGP45HT, and switch between verified presets.
#
# Why these two packs: they are exactly what ROCKNIX mounts (its tmp-shaders.mount
# stacks common-shaders + glsl-shaders + slang-shaders, tmp-overlays.mount wraps
# retroarch-overlays). On this board RA64 runs video_driver="gl" (its Vulkan
# cannot create a display surface), so the reachable presets are the .glslp ones;
# the slang tree is installed too for any board where Vulkan works.
#
#   ./ngp-shaders.sh install            download + verify + unpack + point RA at it
#   ./ngp-shaders.sh install_masks p    unpack a 768P PNG-mask pack into /opt/ngp-shaders/masks768
#   ./ngp-shaders.sh masks on           auto-load one mask per ROM directory (gba/, nes/, ...)
#   ./ngp-shaders.sh masks list         which mask each directory gets
#   ./ngp-shaders.sh masks gba GBA_768P pick a different mask for one directory
#   ./ngp-shaders.sh masks off|status   remove / show the per-directory overrides
#   ./ngp-shaders.sh apply lcd          enable a preset globally (see list)
#   ./ngp-shaders.sh percore lcd gba gb per-core preset: GBA/GB get the LCD mask,
#                                       everything else stays untouched
#   ./ngp-shaders.sh percore off arcade write an explicit "no shader" for a group
#   ./ngp-shaders.sh verify mgba        headless proof that RA loads the override
#   ./ngp-shaders.sh off                shader + PNG overlay off
#   ./ngp-shaders.sh measure on|off     on-screen fps overlay for benchmarking
#   ./ngp-shaders.sh list               show available profiles
#   ./ngp-shaders.sh status             what is enabled right now

SLANG_SHA=5ae2a62cd8dde3e3c435fda9bcd2f6763a4ba63edaef9fabf1b67f2a71aa1800
OVLVLA_SHA=4025f26129d3278aa650acffab6a7823c79299d0de0dd9e2599440fb47e649dd
SLANG_URL=https://codeload.github.com/libretro/slang-shaders/tar.gz/a2ac00bcd5a44982ecaa6ba6e5b8cc9a9608b1d6
OVLVLA_URL=https://codeload.github.com/libretro/common-overlays/tar.gz/ea3f2bf187ae814fdd90431cf796dfe1438cf98c

# NOT under /roms: dArkOS's "Switch to ... SD for Roms" scripts run
#   sed -i '/roms2/s//roms/g'  on both retroarch.cfg files (and the inverse),
# so any absolute /roms/... key gets rewritten to a card that may not hold the
# files -> RA cannot open the preset and exits on content load. /opt is the
# btrfs rootfs of the system card and is never rewritten; /opt/system/Tools is
# excluded because the switch scripts bind-mount over it.
SHADERS=/opt/ngp-shaders/shaders
OVERLAYS=/opt/ngp-shaders/overlays
STAGE=/opt/ngp-shaders/cache
LEGACY=/roms/shaders
LEGACY_OVL=/roms/overlays
CFG=/home/ark/.config/retroarch/retroarch.cfg
GLSL_OLD=/home/ark/.config/retroarch/shaders/shaders_glsl
# the armhf RetroArch is a separate config tree and runs video_driver="gl",
# so it can browse the same packs but must use .glslp, never .slangp
CFG32=/home/ark/.config/retroarch32/retroarch.cfg

# Both tables were verified file-by-file inside the packs on the card.
# The driver decides which one applies: this board's Vulkan cannot create a
# display surface (RA aborts at video init), so RA runs video_driver="gl" and
# only the .glslp table is reachable; the slang table stays for any board where
# Vulkan works. Mega Bezel exists only as slang.
declare -A PS=(
  [zfast-lcd]="handheld/zfast-lcd.slangp"
  [lcd]="handheld/lcd-grid-v2.slangp"
  [lcd1]="handheld/lcd-grid.slangp"
  [dot]="handheld/dot.slangp"
  [lcdshader]="handheld/lcd-shader.slangp"
  [easymode]="crt/crt-easymode.slangp"
  [cgwg]="crt/crt-cgwg-fast.slangp"
  [aperture]="crt/crt-aperture.slangp"
  [geom]="crt/crt-geom.slangp"
  [royale]="crt/crt-royale.slangp"
  [mbz-potato]="bezel/Mega_Bezel/Presets/Base_CRT_Presets/MBZ__5__POTATO__LCD-GRID.slangp"
  [mbz-std]="bezel/Mega_Bezel/Presets/Base_CRT_Presets/MBZ__3__STD__LCD-GRID.slangp"
)
declare -A PG=(
  [zfast-lcd]="handheld/zfast-lcd.glslp"
  [lcd]="handheld/lcd-grid-v2.glslp"
  [lcd1]="handheld/lcd-grid.glslp"
  [dot]="handheld/dot.glslp"
  [lcdshader]="handheld/lcd-shader.glslp"
  [easymode]="crt/crt-easymode.glslp"
  [cgwg]="crt/crt-cgwg-fast.glslp"
  [aperture]="crt/crt-aperture.glslp"
  [geom]="crt/crt-geom.glslp"
  [royale]="crt/crt-royale.glslp"
  [pi]="crt/crt-pi.glslp"
  [hyllian]="crt/crt-hyllian.glslp"
)

declare -A O=(
  [grid]="effects/patterns/grid.cfg"
  [grid2x]="effects/patterns/grid2x.cfg"
  [grille3x]="effects/scanlines/aperture-grille-3x.cfg"
  [scan-alpha]="ctr/effects/scanlines-alpha.cfg"
)

# ---------------------------------------------------------------------------
# The "768P" PNG masks: 1024x768 full-screen bezels whose transparent window is
# exactly the system framebuffer times an integer, so video_scale_integer=true
# lands the image pixel-perfect inside the hole (measured off the PNGs' alpha):
#   gba  240x160 x4 = 960x640 @32,64      nes/snes 256x224 x3 = 768x672 @128,48
#   gb/gbc 160x144 x5 = 800x720 @112,24   megadrive 320x224 x3 = 960x672 @32,48
#   wsc  224x144 x4 = 896x576 @64,96      pico-8 128x128 x6 = 768x768 @128,0
# The *_Grid variants also draw a translucent LCD grid over the window, which is
# what replaces the glsl LCD shader here (hence video_shader_enable=false below).
MASKS=/opt/ngp-shaders/masks768
MASKCONF=/opt/ngp-shaders/masks.conf   # dir=mask choices, written by "masks <dir> <mask>"

declare -A MASKOF=(
  [gba]=GBA_768P_Grid [gbc]=GBC_768P_Grid [gb]=GB_768P_SHADER_DMG
  [nes]=NES_8-7_768P [famicom]=FC_8-7_768P [fds]=FC_8-7_768P
  [snes]=SNES_8-7_768P [sfc]=SFC_8-7_768P
  [megadrive]=MD_768P [genesis]=MD_768P
  [wonderswan]=WSC_768P [wonderswancolor]=WSC_768P
  [ngp]=NGPC_768P [ngpc]=NGPC_768P [pico-8]=PICO_768P
)
declare -A SYSCORES=(
  [gba]="mgba mgba_rumble vba_next gpsp vbam"
  [gb]="gambatte sameboy tgbdual DoubleCherryGB gearboy"
  [gbc]="gambatte sameboy tgbdual DoubleCherryGB gearboy"
  [nes]="fceumm nestopia quicknes"
  [famicom]="fceumm nestopia quicknes"
  [fds]="fceumm nestopia quicknes"
  [snes]="snes9x bsnes snes9x2010 snes9x2005 snes9x2002 bnes mednafen_supafaust"
  [sfc]="snes9x bsnes snes9x2010 snes9x2005 snes9x2002 bnes mednafen_supafaust"
  [megadrive]="genesis_plus_gx genesis_plus_gx_wide genesis_plus_gx_EX picodrive"
  [genesis]="genesis_plus_gx genesis_plus_gx_wide genesis_plus_gx_EX picodrive"
  [wonderswan]="mednafen_wswan swanstation"
  [wonderswancolor]="mednafen_wswan swanstation"
  [ngp]="mednafen_ngp race"
  [ngpc]="mednafen_ngp race"
  [pico-8]="fake08"
)

driver_of() { grep -a '^video_driver *=' "$1" | tail -1 | sed 's/.*= *"//; s/".*//'; }
driver() { driver_of "$CFG"; }

setkey_in() { # setkey_in <cfg> <key> <value>   -- rewrites or appends one cfg line
  local f="$1" k="$2" v="$3"
  if grep -qa "^${k} *=" "$f"; then
    sed -i "s|^${k} *=.*|${k} = \"${v}\"|" "$f"
  else
    echo "${k} = \"${v}\"" >>"$f"
  fi
}
setkey() { setkey_in "$CFG" "$1" "$2"; }

getkey() { grep -a "^$1 *=" "$CFG" | tail -1; }

# dArkOS keeps two independent RetroArch trees; both run video_driver="gl" here.
allcfgs() { local f; for f in "$CFG" "$CFG32"; do [ -f "$f" ] && echo "$f"; done; }
raname() { basename "$(dirname "$1")"; }   # .../retroarch32/retroarch.cfg -> retroarch32

# RA resolves these from the cfg, not from hardcoded paths: rgui_config_directory is the
# "config directory" that config_load_override() builds its per-core path from, and
# libretro_directory is where the .so/.info files live.
cfgdir_of() { # cfgdir_of <cfg> <key> <fallback-subdir>
  local f="$1" d
  d=$(grep -a "^$2 *=" "$f" | tail -1 | sed 's/.*= *"//; s/"$//')
  [ -n "$d" ] || d="$(dirname "$f")/$3"
  echo "${d/#\~//home/ark}"
}
confdir_of() { cfgdir_of "$1" rgui_config_directory config; }
coredir_of() { cfgdir_of "$1" libretro_directory cores; }

fetch() { # fetch <url> <sha> <out>
  [ -s "$3" ] && sha256sum -c <(echo "$2  $3") >/dev/null 2>&1 && { echo "cached: $3"; return 0; }
  echo "downloading $(basename "$3")"
  curl -sL --fail --max-time 600 -o "$3" "$1" || { echo "DOWNLOAD FAILED: $1"; return 1; }
  sha256sum "$3"
  echo "$2  $3" | sha256sum -c - || { echo "SHA256 MISMATCH for $3"; return 1; }
}

install() {
  [ -f "$CFG" ] || { echo "no retroarch.cfg at $CFG"; exit 1; }
  [ -f "$CFG.bak-shaders" ] || cp "$CFG" "$CFG.bak-shaders"
  mkdir -p "$STAGE" "$SHADERS" "$OVERLAYS"
  if [ -d "$LEGACY" ] || [ -d "$LEGACY_OVL" ]; then
    echo "== removing the old /roms copies (that path is rewritten by the SD switch) =="
    rm -rf "$LEGACY" "$LEGACY_OVL"
  fi
  fetch "$SLANG_URL" "$SLANG_SHA" "$STAGE/slang.tar.gz" || exit 1
  fetch "$OVLVLA_URL" "$OVLVLA_SHA" "$STAGE/overlays.tar.gz" || exit 1

  echo "== unpack slang =="
  rm -rf "$SHADERS/shaders_slang"
  mkdir -p "$SHADERS/shaders_slang"
  tar -xzf "$STAGE/slang.tar.gz" -C "$SHADERS/shaders_slang" --strip-components=1 --no-same-owner --no-same-permissions || exit 1
  echo "   slangp=$(find "$SHADERS/shaders_slang" -name '*.slangp' | wc -l) slang=$(find "$SHADERS/shaders_slang" -name '*.slang' | wc -l)"

  echo "== unpack overlays (borders ctr effects misc; gamepad/keyboard packs pruned) =="
  rm -rf "$OVERLAYS/.tmp" "$SHADERS/.tmp"
  mkdir -p "$OVERLAYS/.tmp"
  tar -xzf "$STAGE/overlays.tar.gz" -C "$OVERLAYS/.tmp" --no-same-owner --no-same-permissions || exit 1
  inner=$(ls "$OVERLAYS/.tmp")
  for d in borders ctr effects misc; do
    rm -rf "$OVERLAYS/$d"
    mv "$OVERLAYS/.tmp/$inner/$d" "$OVERLAYS/$d" || { echo "missing $d in pack"; exit 1; }
  done
  rm -rf "$OVERLAYS/.tmp"
  echo "   overlay cfg=$(find "$OVERLAYS" -name '*.cfg' | wc -l) png=$(find "$OVERLAYS" -name '*.png' | wc -l)"

  if [ ! -e "$SHADERS/shaders_glsl" ] && [ -d "$GLSL_OLD" ]; then
    echo "== linking the base image's glsl tree so one dir holds both backends =="
    ln -sfn "$GLSL_OLD" "$SHADERS/shaders_glsl"   # btrfs can do symlinks, unlike exFAT
  fi
  setkey video_shader_dir "$SHADERS"
  setkey video_overlay_dir "$OVERLAYS"
  if [ -f "$CFG32" ]; then
    [ -f "$CFG32.bak-shaders" ] || cp "$CFG32" "$CFG32.bak-shaders"
    CFGBAK="$CFG"; CFG="$CFG32"
    setkey video_shader_dir "$SHADERS"; setkey video_overlay_dir "$OVERLAYS"
    CFG="$CFGBAK"
    echo "   also pointed $CFG32 at $SHADERS (it is gl: use .glslp there)"
  fi
  chown -R ark:ark "$SHADERS" "$OVERLAYS" 2>/dev/null
  df -h /roms | tail -1
  echo "install done. now:  $0 apply lcd   (or: $0 list)"
}

apply() {
  local name="$1"
  local drv sub p
  drv=$(driver)
  if [ "$drv" = "vulkan" ]; then sub=shaders_slang; p="${PS[$name]}"; else sub=shaders_glsl; p="${PG[$name]}"; fi
  if [ -z "$p" ]; then
    case "$name" in *.slangp|*.glslp|*/*) p="$name" ;; esac
  fi
  [ -n "$p" ] || { echo "unknown profile '$name' for driver '$drv'"; list; exit 1; }
  case "$p" in /*) abs="$p" ;; *) abs="$SHADERS/$sub/$p" ;; esac
  [ -f "$abs" ] || { echo "preset missing ($abs), run: $0 install"; exit 1; }
  setkey video_shader "$abs"
  setkey video_shader_enable true
  echo "shader -> $abs"
}

overlay() {
  local name="$1"
  local o="${O[$name]}"
  [ -n "$o" ] || { echo "unknown overlay '$name'"; exit 1; }
  [ -f "$OVERLAYS/$o" ] || { echo "overlay missing, run: $0 install"; exit 1; }
  setkey input_overlay "$OVERLAYS/$o"
  setkey input_overlay_enable true
  setkey input_overlay_opacity 0.35
  echo "overlay -> $name = $o"
}

off() {
  local f
  for f in $(allcfgs); do
    setkey_in "$f" video_shader_enable false
    setkey_in "$f" input_overlay ""
    setkey_in "$f" input_overlay_enable false
  done
  echo "shader + overlay off in both RA trees"
  echo "note: per-core / per-directory override files still apply -- $0 percore off all, $0 masks off"
}

measure() { # fps OSD, both RA trees. RA 1.22 names: fps_show / framecount_show / memory_show
            # (the pre-1.10 name video_perf_present is ignored by this build)
  local x=${FPS_X:-0.86} y=${FPS_Y:-0.02} f
  case "$1" in
    on)  for f in $(allcfgs); do
           setkey_in "$f" fps_show true
           setkey_in "$f" framecount_show false
           setkey_in "$f" memory_show false
           setkey_in "$f" video_font_enable true
           setkey_in "$f" video_message_pos_x "$x"
           setkey_in "$f" video_message_pos_y "$y"
           sed -i '/^video_perf_present =/d' "$f"
           echo "  $(raname "$f"): fps OSD on at x=$x y=$y (top-right)"
         done ;;
    off) for f in $(allcfgs); do
           setkey_in "$f" fps_show false
           setkey_in "$f" framecount_show false
           setkey_in "$f" memory_show false
           sed -i '/^video_perf_present =/d' "$f"
           echo "  $(raname "$f"): fps OSD off"
         done ;;
    left) FPS_X=0.05 FPS_Y=0.05 measure on ;;
    *)   echo "usage: $0 measure on|off|left"; exit 1 ;;
  esac
}

list() {
  local drv=$(driver) k sub
  echo "== shader profiles for video_driver="$drv" (every path verified on the card) =="
  echo "   any relative path also works:  apply crt/crt-easymode.glslp"
  if [ "$drv" = "vulkan" ]; then sub=shaders_slang
    for k in zfast-lcd lcd lcd1 dot lcdshader easymode cgwg aperture geom royale mbz-potato mbz-std; do
      printf "  %-12s %s/%s
" "$k" "$sub" "${PS[$k]}"; done
  else sub=shaders_glsl
    for k in zfast-lcd lcd lcd1 dot lcdshader easymode cgwg aperture geom royale pi hyllian; do
      printf "  %-12s %s/%s
" "$k" "$sub" "${PG[$k]}"; done
    echo "  (mbz-* is slang-only and needs Vulkan, which this board cannot use)"
  fi
  echo "== PNG overlays (border/decoration only: full_screen=true does NOT follow the game image) =="
  for k in grid grid2x grille3x scan-alpha; do printf "  %-12s %s\n" "$k" "${O[$k]}"; done
}

# RA keys the per-core override on the core's library_name (retro_get_system_info), which its
# .info mirrors as `corename`, not on the .so basename -- mgba and mgba_rumble both report
# corename=mGBA, so one file covers both.
corename_of() { # corename_of <core> <cores-dir>
  local f="$2/$1_libretro.info" n
  [ -f "$f" ] || return 1
  n=$(grep -a '^corename' "$f" | tail -1 | sed 's/.*= *//; s/^"//; s/"$//')
  [ -n "$n" ] && echo "$n" || return 1
}

group_cores() { # group_cores <group> [cores-dir]
  case "$1" in
    gba)      echo "mgba mgba_rumble vba_next gpsp vbam" ;;
    gb)       echo "gambatte sameboy" ;;
    handheld) echo "mgba mgba_rumble vba_next gpsp vbam gambatte sameboy handy pokemini mednafen_wswan swanstation" ;;
    arcade)   echo "fbneo mame2003_plus mame mame2010 hbmame fbalpha2012 fbalpha2012_cps1 fbalpha2012_cps2 fbalpha2012_cps3" ;;
    all)      ls "$2"/*.so 2>/dev/null | sed 's#.*/##; s/_libretro\.so$//' ;;
    *)        echo "$1" ;;
  esac
}

# config_load_override() (configuration.c) builds exactly one per-core path:
#   <config_directory>/<library_name>/<library_name>.cfg
# with config_directory = the cfg's `rgui_config_directory` (file_path_special.c,
# APPLICATION_SPECIAL_DIRECTORY_CONFIG) and library_name from the core itself.
# A flat <config_directory>/<library_name>.cfg is never even stat()ed -- writing one silently
# does nothing, which is how the first version of this shipped a shader that never applied.
percore() { # percore <profile|off> <core-or-group>...
  local prof=$1; shift
  [ -n "$prof" ] || { echo "usage: $0 percore <profile|off> <core-or-group>..."; exit 1; }
  local abs="" sub drv n f t c tree cd cr wrote=0
  for tree in $(allcfgs); do
    cd=$(confdir_of "$tree"); cr=$(coredir_of "$tree"); drv=$(driver_of "$tree")
    abs=""
    if [ "$prof" != "off" ]; then
      if [ "$drv" = "vulkan" ]; then sub=shaders_slang; abs="$SHADERS/$sub/${PS[$prof]}"
      else sub=shaders_glsl; abs="$SHADERS/$sub/${PG[$prof]}"; fi
      [ -f "$abs" ] || { echo "preset missing for $drv: $abs (run: $0 list)"; exit 1; }
    fi
    echo "== $(raname "$tree") ($drv)  overrides under $cd =="
    for t in "$@"; do
      for c in $(group_cores "$t" "$cr"); do
        [ -f "$cr/${c}_libretro.so" ] || continue
        n=$(corename_of "$c" "$cr") || { echo "  skip $c (no corename in its .info)"; continue; }
        rm -f "$cd/$n.cfg"                      # stale flat file from the old layout
        mkdir -p "$cd/$n"
        f="$cd/$n/$n.cfg"
        if [ -z "$abs" ]; then
          printf 'video_shader_enable = "false"\n' > "$f"
        else
          printf 'video_shader_enable = "true"\nvideo_shader = "%s"\n' "$abs" > "$f"
        fi
        chown -R ark:ark "$cd/$n" 2>/dev/null
        echo "  $c -> $n/$n.cfg  ${abs:-<shader off>}"
        wrote=$((wrote+1))
      done
    done
  done
  echo "per-core files written: $wrote   (global video_shader_enable=$(getkey video_shader_enable | sed 's/.*= //'))"
}

png_size() { # png_size <file> -> WxH straight out of IHDR, no python/PIL needed
  local w h
  set -- $(dd if="$1" bs=1 skip=16 count=8 2>/dev/null | od -An -tx1 | tr -s ' ')
  [ $# -ge 8 ] || { echo "?x?"; return 1; }
  w=$((16#$1 * 16777216 + 16#$2 * 65536 + 16#$3 * 256 + 16#$4))
  h=$((16#$5 * 16777216 + 16#$6 * 65536 + 16#$7 * 256 + 16#$8))
  echo "${w}x${h}"
}

install_masks() { # install_masks [tarball|dir]
  local src=${1:-/home/ark/masks768.tar.gz} cfg png n bad=0
  [ -e "$src" ] || { echo "no mask pack at $src"; exit 1; }
  mkdir -p "$MASKS"
  case "$src" in
    *.tar.gz|*.tgz) tar -xzf "$src" -C "$MASKS" --no-same-owner --no-same-permissions || exit 1 ;;
    *) cp -a "$src"/. "$MASKS"/ || exit 1 ;;
  esac
  chown -R ark:ark "$MASKS"
  for cfg in "$MASKS"/*.cfg; do
    [ -f "$cfg" ] || continue
    png=$(grep -a '^overlay0_overlay' "$cfg" | head -1 | sed 's/.*= *//; s/^"//; s/"$//' | tr -d ' \r')
    if [ -z "$png" ] || [ ! -f "$MASKS/$png" ]; then
      echo "  !! $(basename "$cfg") points at a missing png ($png)"; bad=$((bad + 1)); continue
    fi
    n=$(png_size "$MASKS/$png")
    [ "$n" = "1024x768" ] || { echo "  !! $png is $n, not 1024x768 (full_screen=true would stretch it)"; bad=$((bad + 1)); }
  done
  echo "masks installed: $(ls "$MASKS"/*.cfg 2>/dev/null | wc -l) cfg + $(ls "$MASKS"/*.png 2>/dev/null | wc -l) png in $MASKS (problems: $bad)"
  [ "$bad" = 0 ]
}

mask_for() { # mask_for <roms-dir> -> chosen mask basename (MASKCONF beats MASKOF)
  local v
  [ -f "$MASKCONF" ] && v=$(grep -a "^$1=" "$MASKCONF" | tail -1 | cut -d= -f2-)
  [ -n "$v" ] && echo "$v" || echo "${MASKOF[$1]}"
}

# Per-content-directory overrides: config_load_override() also builds
# <config_dir>/<library_name>/<parent-dir-of-the-ROM>.cfg and stacks it ON TOP of the
# per-core file, which is what makes "auto by game category" possible -- one core
# (Gambatte) can serve gb/ and gbc/ with two different masks.
write_mask() { # write_mask <tree-cfg> <roms-dir> <mask|off>
  local tree=$1 d=$2 m=$3 cr cd core n f wrote=0
  cr=$(coredir_of "$tree"); cd=$(confdir_of "$tree")
  for core in ${SYSCORES[$d]}; do
    [ -f "$cr/${core}_libretro.so" ] || continue
    n=$(corename_of "$core" "$cr") || continue
    if [ "$m" = "off" ]; then rm -f "$cd/$n/$d.cfg"; wrote=$((wrote + 1)); continue; fi
    mkdir -p "$cd/$n"
    f="$cd/$n/$d.cfg"
    {
      echo 'input_overlay_enable = "true"'
      echo "input_overlay = \"$MASKS/$m.cfg\""
      echo 'input_overlay_opacity = "1.000000"'
      echo 'input_overlay_show_offscreen = "false"'
      echo 'video_scale_integer = "true"'
      echo 'video_shader_enable = "false"'
    } >"$f"
    chown -R ark:ark "$cd/$n" 2>/dev/null
    echo "    $(raname "$tree") $core -> $n/$d.cfg = $m"
    wrote=$((wrote + 1))
  done
  [ "$wrote" = 0 ] && echo "    ($(raname "$tree"): none of the $d cores installed)"
  return 0
}

masks() { # masks on|off|status|list | masks <roms-dir> <mask|off>
  local mode=${1:-status} d m tree cd f b c
  case "$mode" in
    list)
      echo "== masks in $MASKS =="
      for f in "$MASKS"/*.cfg; do
        [ -f "$f" ] || continue
        b=$(basename "$f" .cfg)
        printf "  %-28s %s\n" "$b" "$(png_size "$MASKS/$b.png" 2>/dev/null)"
      done
      echo "== roms dir -> mask (defaults, MASKCONF wins) =="
      for d in $(echo "${!MASKOF[@]}" | tr ' ' '\n' | sort); do
        printf "  %-18s %s\n" "$d" "$(mask_for "$d")"
      done ;;
    on)
      [ -d "$MASKS" ] || { echo "no masks installed; run: $0 install_masks <pack>"; exit 1; }
      for d in $(echo "${!MASKOF[@]}" | tr ' ' '\n' | sort); do
        m=$(mask_for "$d")
        [ -n "$m" ] && [ "$m" != "off" ] || continue
        [ -f "$MASKS/$m.cfg" ] || { echo "  !! $d wants $m but $MASKS/$m.cfg is missing"; continue; }
        echo "  /roms/$d ($([ -d "/roms/$d" ] && ls "/roms/$d" 2>/dev/null | wc -l || echo 0) files)"
        for tree in $(allcfgs); do write_mask "$tree" "$d" "$m"; done
      done ;;
    off)
      for d in "${!MASKOF[@]}"; do for tree in $(allcfgs); do write_mask "$tree" "$d" off >/dev/null; done; done
      echo "per-directory mask overrides removed" ;;
    status)
      for tree in $(allcfgs); do
        cd=$(confdir_of "$tree")
        echo "== $(raname "$tree") per-directory overrides under $cd =="
        for f in "$cd"/*/*.cfg; do
          [ -f "$f" ] || continue
          b=$(basename "$f" .cfg); c=$(basename "$(dirname "$f")")
          case " ${!MASKOF[@]} " in *" $b "*) ;; *) continue ;; esac
          printf "   %-18s %-22s %s\n" "$b" "$c" \
            "$(grep -a '^input_overlay =' "$f" | tail -1 | sed 's#.*/##; s/\.cfg"$//')"
        done
      done ;;
    *)
      d="$mode"; m="$2"
      case " ${!MASKOF[@]} " in *" $d "*) ;; *)
        echo "unknown roms dir '$d'; known: $(echo "${!MASKOF[@]}" | tr ' ' '\n' | sort | tr '\n' ' ')"; exit 1 ;;
      esac
      if [ "$m" != "off" ] && [ ! -f "$MASKS/$m.cfg" ]; then
        echo "no such mask: '$m' (run: $0 masks list)"; exit 1
      fi
      { [ -f "$MASKCONF" ] && grep -av "^$d=" "$MASKCONF"; echo "$d=$m"; } >"$MASKCONF.tmp"
      mv "$MASKCONF.tmp" "$MASKCONF"
      echo "$d -> $m"
      for tree in $(allcfgs); do write_mask "$tree" "$d" "$m"; done ;;
  esac
}

verify() { # verify <core> [rom]  -- headless proof that RA really loads the override.
  # Runs against a COPY of the cfg. RA rewrites the whole config on exit
  # (config_save_on_exit=true), so an --appendconfig carrying null drivers once got saved
  # straight into the real file and left the card with video_driver="null" (black screen).
  local c=${1:-mgba} rom="$2" tree cd cr n ra r ran=0 copy snap
  [ "$(id -u)" = 0 ] || { echo "$0 verify needs root (it drops to ark to run RA)"; exit 1; }
  printf 'video_driver = "null"\naudio_driver = "null"\ninput_driver = "null"\nmenu_driver = "null"\nconfig_save_on_exit = "false"\nlog_verbosity = "true"\n' >/tmp/ngp-verify-append.cfg
  for tree in $(allcfgs); do
    cr=$(coredir_of "$tree"); cd=$(confdir_of "$tree")
    [ -f "$cr/${c}_libretro.so" ] || continue
    n=$(corename_of "$c" "$cr") || { echo "  $(raname "$tree"): $c has no corename"; continue; }
    ra="/opt/retroarch/bin/$(raname "$tree")"
    r="$rom"
    [ -n "$r" ] || r=$(ls /roms/gba/*.zip /roms/gba/*.gba 2>/dev/null | head -1)
    [ -f "$r" ] || { echo "  $(raname "$tree"): no test content for $c"; continue; }
    copy="/tmp/ngp-verify-$(raname "$tree").cfg"; snap="$copy.orig"
    cp "$tree" "$copy"; cp "$tree" "$snap"; chown ark:ark "$copy"
    echo "== $(raname "$tree") + $c (override name: $n) =="
    sudo -u ark env HOME=/home/ark XDG_CONFIG_HOME=/home/ark/.config timeout 60 "$ra" \
      -c "$copy" --appendconfig /tmp/ngp-verify-append.cfg -L "$cr/${c}_libretro.so" \
      -v --max-frames 3 "$r" >/tmp/ngp-verify.log 2>&1
    echo "  rc=$?  content=$r"
    grep -a '\[Override\]' /tmp/ngp-verify.log | grep -av 'srm\|state' \
      || echo "  !! NO override loaded; RA looked for $cd/$n/$n.cfg (and $cd/$n/<romdir>.cfg)"
    if [ "$(md5sum <"$tree")" != "$(md5sum <"$snap")" ]; then
      cp "$snap" "$tree"; chown ark:ark "$tree"
      echo "  !! RA rewrote $tree during the probe -- restored from snapshot"
    fi
    rm -f "$copy" "$snap"
    ran=1
  done
  [ "$ran" = 1 ] || { echo "nothing verified: core '$c' is not installed"; exit 1; }
}

status() {
  echo "shader_dir : $(getkey video_shader_dir)"
  echo "overlay_dir: $(getkey video_overlay_dir)"
  echo "driver     : $(getkey video_driver)"
  echo "enable     : $(getkey video_shader_enable)"
  echo "shader     : $(getkey video_shader)"
  echo "video_filt : $(getkey video_filter)"
  echo "input_ovl  : $(getkey input_overlay)"
  local tree cd f
  for tree in $(allcfgs); do
    cd=$(confdir_of "$tree")
    echo "== $(raname "$tree")  fps_show=$(grep -a '^fps_show *=' "$tree" | tail -1 | sed 's/.*= *//')  overrides in $cd =="
    for f in "$cd"/*/*.cfg; do
      [ -f "$f" ] || continue
      case "$f" in */remaps/*) continue ;; esac
      printf "   %-24s %s\n" "$(basename "$(dirname "$f")")" \
        "$(grep -a '^video_shader =' "$f" | tail -1 | sed 's#.*/##; s/"$//')"
    done
    for f in "$cd"/*.cfg; do
      [ -f "$f" ] && echo "   !! stale flat file that RA never reads: $f"
    done
  done
  local abs=$(getkey video_shader | sed 's/.*= "//; s/"$//')
  echo "installed  : slangp=$(find "$SHADERS/shaders_slang" -name '*.slangp' 2>/dev/null | wc -l) glslp=$(find -L "$SHADERS" -name '*.glslp' 2>/dev/null | wc -l) overlay_cfg=$(find "$OVERLAYS" -name '*.cfg' 2>/dev/null | wc -l)"
  if [ -n "$abs" ] && [ ! -f "$abs" ]; then
    echo "!! preset path in cfg does not exist ($abs) -> RA would exit on load. run: $0 repair"
  fi
}

repair() { # re-point a shader/overlay that a SD switch rewrote to a missing card
  local abs=$(getkey video_shader | sed 's/.*= "//; s/"$//')
  local rel=""
  case "$abs" in *shaders_slang/*) rel=${abs#*shaders_slang/} ;; *shaders_glsl/*) rel=${abs#*shaders_glsl/} ;; esac
  if [ -n "$rel" ] && [ -f "$SHADERS/shaders_slang/$rel" ]; then
    if [ -f "$SHADERS/shaders_slang/$rel" ]; then setkey video_shader "$SHADERS/shaders_slang/$rel"
    elif [ -f "$SHADERS/shaders_glsl/$rel" ]; then setkey video_shader "$SHADERS/shaders_glsl/$rel"; fi
    echo "repair: video_shader -> $(getkey video_shader)"
  elif [ -n "$abs" ] && [ ! -f "$abs" ]; then
    setkey video_shader_enable false
    echo "repair: preset $abs gone and could not remap -> shader disabled so games still launch"
  else
    echo "repair: nothing to do ($abs)"
  fi
  for f in "$CFG" "$CFG32"; do
    [ -f "$f" ] || continue
    sed -i "\|/roms/shaders|d; \|^video_shader_dir = "~/.config/retroarch3*/shaders"|d" "$f" 2>/dev/null
    if grep -qa "^video_shader_dir *=" "$f"; then sed -i "s|^video_shader_dir *=.*|video_shader_dir = \"$SHADERS\"|" "$f"; else echo "video_shader_dir = \"$SHADERS\"" >>"$f"; fi
    if grep -qa "^video_overlay_dir *=" "$f"; then sed -i "s|^video_overlay_dir *=.*|video_overlay_dir = \"$OVERLAYS\"|" "$f"; else echo "video_overlay_dir = \"$OVERLAYS\"" >>"$f"; fi
    echo "repair: $f dirs re-pointed"
  done
}

case "${1:-status}" in
  install) install ;;
  apply) apply "${2:-lcd}" ;;
  overlay) overlay "${2:-grid}" ;;
  off) off ;;
  percore) shift; percore "${1:-off}" "${@:2}" ;;
  install_masks) install_masks "${2:-}" ;;
  masks) shift; masks "$@" ;;
  verify) verify "${2:-mgba}" "${3:-}" ;;
  repair) repair ;;
  measure) measure "${2:-on}" ;;
  list) list ;;
  status) status ;;
  *) echo "usage: $0 [install|apply <p>|overlay <o>|off|repair|measure on|off|list|status]"; list; exit 1 ;;
esac
