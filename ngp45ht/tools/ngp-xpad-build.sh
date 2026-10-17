#!/bin/bash
# Build xpad.ko out-of-tree against the same tree that produced the card's running
# kernel (5.10.226), without touching that tree's .config: the slim ngp45ht config
# has "# CONFIG_JOYSTICK_XPAD is not set", so a 045e:028e (Xbox 360 / most 2.4G
# XInput receivers) device gets no driver at all.
#
# CONFIG_JOYSTICK_XPAD_FF is injected via ccflags so rumble is compiled in; it needs
# input_ff_create_memless(), and CONFIG_INPUT_FF_MEMLESS=y is already in the kernel.
# LEDS is deliberately left off (needs CONFIG_LEDS_CLASS, not verified here).
set -x
BLD=/root/ngp/kernel_rk3562
W=/root/ngp/xpad-mod
OUT=/mnt/f/darkos/_work/ngpout

[ -f "$BLD/drivers/input/joystick/xpad.c" ] || { echo "no xpad.c in $BLD"; exit 1; }
rm -rf "$W"; mkdir -p "$W" "$OUT"
cp "$BLD/drivers/input/joystick/xpad.c" "$W/"

cat >"$W/Makefile" <<'EOF'
obj-m := xpad.o
ccflags-y += -DCONFIG_JOYSTICK_XPAD_FF
KDIR ?= /root/ngp/kernel_rk3562
all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules
EOF

echo "== kernel tree identity =="
grep -aE '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION)' "$BLD/Makefile" | head -4
grep -a '^CONFIG_LOCALVERSION=' "$BLD/.config"

echo "== build =="
cd "$W" || exit 1
make 2>&1 | tail -25
rc=${PIPESTATUS[0]}
echo "make rc=$rc"
[ -f "$W/xpad.ko" ] || { echo "NO xpad.ko produced"; exit 1; }

echo "== result =="
ls -la "$W/xpad.ko"
aarch64-linux-gnu-strip --strip-debug "$W/xpad.ko" 2>/dev/null
ls -la "$W/xpad.ko"
modinfo "$W/xpad.ko" 2>/dev/null | grep -E '^(filename|vermagic|name|description|depends|alias)' | head -12
echo "  alias count: $(modinfo "$W/xpad.ko" 2>/dev/null | grep -c '^alias')"
echo "  045e:028e covered: $(modinfo "$W/xpad.ko" 2>/dev/null | grep -ci 'v0000045E.*p0000028E')"
sha256sum "$W/xpad.ko"
cp "$W/xpad.ko" "$OUT/xpad.ko"
echo "copied to $OUT/xpad.ko"
