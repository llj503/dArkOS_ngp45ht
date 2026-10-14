#!/bin/bash
# Apply (or with --revert, undo) the NGP45HT kernel patches.  Run from anywhere;
# pass the kernel tree path as the last argument.  Nothing else in the tree is
# touched: every patch is --check'ed first and either all of them apply or the
# script stops before writing.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REV=""
K=kernel_rk3562
for a in "$@"; do
    [ "$a" = "--revert" ] && REV=-R || K="$a"
done
cd "$K" || { echo "kernel tree not found: $K"; exit 1; }
for p in "$HERE"/0*.patch; do
    echo "== $(basename "$p")"
    git apply $REV --check "$p" || { echo "$REV check FAILED: $p (already applied?)"; exit 1; }
done
for p in "$HERE"/0*.patch; do
    git apply $REV "$p"
done
echo "done. Build it with:"
echo "  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- ngp45ht_defconfig"
echo "  make -j\$(nproc) Image modules dtbs"
echo "and read ngp45ht/README.md -- the WiFi modules belong to ngp45ht_defconfig,"
echo "the shipped Image and its out-of-tree .ko must always move together."
