#!/bin/bash
# Install the AIC8800DC USB WiFi stack into the NGP45HT card's rootfs image
# (already loop-mounted read-write at $M).
set -euo pipefail

M=${M:-/mnt/card_root}
DRV=/root/ngp/aic8800-usb
KREL=5.10.226
KSRC=/root/ngp/kernel_rk3562

[ -d "$M/lib" ] || { echo "rootfs not mounted at $M"; exit 1; }

echo "== 1. 模块 =="
mkdir -p "$M/usr/lib/modules/$KREL/extra/aic8800-usb"
cp "$DRV/aic_load_fw/aic_load_fw_usb.ko" "$M/usr/lib/modules/$KREL/extra/aic8800-usb/"
cp "$DRV/aic8800_fdrv/aic8800_fdrv_usb.ko" "$M/usr/lib/modules/$KREL/extra/aic8800-usb/"
ls -la "$M/usr/lib/modules/$KREL/extra/aic8800-usb/"

echo "== 2. 固件 =="
mkdir -p "$M/usr/lib/firmware/aic8800DC"
cp -a "$DRV/aic8800DC/." "$M/usr/lib/firmware/aic8800DC/"
echo "   $(ls "$M/usr/lib/firmware/aic8800DC" | wc -l) 个文件"

echo "== 3. modprobe 顺序 =="
mkdir -p "$M/etc/modprobe.d"
cat > "$M/etc/modprobe.d/aic8800-usb.conf" <<'CONF'
# aic8800_fdrv_usb needs the RAM-firmware loader bound first: the 8800DC has no
# on-board flash, so aic_load_fw_usb downloads firmware and re-enumerates the
# device before the WLAN driver can claim it.
softdep aic8800_fdrv_usb pre: aic_load_fw_usb
CONF

echo "== 4. 开机加载脚本改为 USB 优先 =="
W=$M/usr/local/bin/wifi-driver-load.sh
cp -a "$W" "$W.rg43h.bak" 2>/dev/null || true
cat > "$W" <<'SH'
#!/bin/sh
# NGP45HT: the wireless module is an AIC8800DC on the USB2 host bus, not the
# SDIO AIC8800D80/RK915 the shared dArkOS rootfs expects.  Try the out-of-tree
# USB stack first and only then fall back to the original SDIO logic.
if modprobe aic8800_fdrv_usb 2>/dev/null; then
    exit 0
fi

if ! modprobe rk915; then
    modprobe aic8800_bsp
    modprobe aic8800_fdrv
fi
SH
chmod 755 "$W"

echo "== 5. depmod =="
depmod -a -F "$KSRC/System.map" -b "$M" "$KREL" && echo "   depmod ok"
grep -c "aic8800_fdrv_usb" "$M/usr/lib/modules/$KREL/modules.dep" || echo "   WARN: 未出现在 modules.dep"

echo "== 6. 校验 =="
modinfo -F filename aic8800_fdrv_usb -k "$KREL" -b "$M" 2>/dev/null || true
sync
echo INSTALL_WIFI_OK
