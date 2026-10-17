#!/bin/bash
#
# Report components that did not make it into the image.
#
# Most build_<emu>sa.sh scripts have no verify_action: when builds-alt.sh fails
# to patch or clone something, the copy that follows finds nothing, prints one
# line, and the build moves on. /opt/<name> still exists because mkdir -p ran
# first, so the directory is there and the binary is not. Across two builds that
# quietly cost us ECWolf, Hypseus Singe, GameTank, Yabasanshiro, freej2me-plus
# and Kodi, each discovered only by reading 80k lines of log afterwards.
#
# Rather than hardcode a list of expected binaries that would rot, look for the
# shape of the failure: a directory under /opt holding no executable at all.
#
# It also reports empty tarballs in the package cache. A failed build used to
# be cached like a successful one, under a key that still matched, so the next
# build restored the failure rather than retrying it - which is how Kodi stayed
# missing across two builds while appearing to have been handled.
#
# Informational only - never fails the build. Reads Arkbuild/, so it has to run
# before cleanup_filesystem.sh.

ARK="${1:-Arkbuild}"
LOG="${2:-build.log}"

echo ""
echo "==================== COMPONENT AUDIT ===================="

empty=0
noexec=0
ok=0

for d in "${ARK}"/opt/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")

    # Shell scripts and data by design - no ELF belongs in these.
    case "$name" in
        cmds|system) ok=$((ok + 1)); continue ;;
    esac

    files=$(sudo find "$d" -type f 2>/dev/null | head -1)
    if [ -z "$files" ]; then
        echo "  EMPTY       /opt/${name}"
        empty=$((empty + 1))
        continue
    fi
    # Look for ELF magic rather than the executable bit. The bit lies in both
    # directions here: hypseus-singe failed to build yet ships a stray +x on
    # hypinput_gamepad.ini, while sdl3-shim is nothing but libraries, which are
    # not executable and should still count. Feeding the first four bytes of
    # every file to grep costs one pass and settles both.
    if ! sudo find "$d" -type f -exec head -c4 {} \; 2>/dev/null | grep -qa $'\x7fELF'; then
        echo "  NO BINARY   /opt/${name}  (files present, no ELF among them)"
        noexec=$((noexec + 1))
        continue
    fi
    ok=$((ok + 1))
done

echo "  ---"
echo "  with binaries: ${ok}   empty: ${empty}   no executable: ${noexec}"

if [ -f "${LOG}" ]; then
    echo ""
    echo "  Build steps that gave up (from ${LOG}):"
    if grep -aq "Stopping here" "${LOG}"; then
        grep -a "Stopping here" "${LOG}" \
            | sed 's/.*applying patch //; s/.*applying //; s/.*cloning the //; s/\. *Stopping here\.*//; s/  *Stopping here\.*//' \
            | sort | uniq -c | sed 's/^/    /'
    else
        echo "    none"
    fi

    echo ""
    echo "  Packages that failed to install:"
    if grep -aq "^Could not install needed library" "${LOG}"; then
        grep -a "^Could not install needed library" "${LOG}" | sort -u | sed 's/^/    /'
    else
        echo "    none"
    fi
fi


CACHE="Arkbuild_package_cache/${CHIPSET:-rk3562}"
if [ -d "${CACHE}" ]; then
    echo ""
    echo "  Cached failures (an empty tarball under a key that still matches,"
    echo "  so every later build restores the failure instead of retrying):"
    bad=$(find "${CACHE}" -name '*.tar.gz' -size -20k -printf '    %s B  %f\n' 2>/dev/null | sort -n)
    if [ -n "${bad}" ]; then
        echo "${bad}"
        echo "    -> delete those .tar.gz and .commit pairs to force a rebuild"
    else
        echo "    none"
    fi
fi

echo "========================================================"
echo ""
