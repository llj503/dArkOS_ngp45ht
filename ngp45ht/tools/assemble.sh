#!/bin/bash
# Assemble dArkOS for NGP45HT from the RG43H base image.
# All writes are to the working copy under /root/ngp/out, never to the base.
set -euo pipefail

OUT=/root/ngp/out/dArkOS_ngp45ht_trixie_20261013.img
W=/mnt/f/darkos/_work
K=/root/ngp/kernel_rk3562

echo "== 0. 前置检查 =="
for f in "$OUT" "$W/ngp_bl8m.img" "$W/ngp_uboot_sdfirst.img" "$W/rk3562-ngp45ht.dtb" \
         "$W/extlinux_ngp.conf" "$K/arch/arm64/boot/Image"; do
  [ -e "$f" ] || { echo "缺少 $f"; exit 1; }
done
ls -la "$OUT" "$K/arch/arm64/boot/Image"

echo "== 1. 写入原厂 idbloader (扇区 64-16383，DDR 初始化必须来自本机) =="
dd if="$W/ngp_bl8m.img" of="$OUT" bs=512 skip=64 seek=64 count=16320 conv=notrunc status=none
echo "   done"

echo "== 2. 写入 SD 优先 + 充电动画的 uboot (扇区 16384) =="
dd if="$W/ngp_uboot_sdfirst.img" of="$OUT" bs=512 seek=16384 conv=notrunc status=none
echo "   done"

echo "== 3. 挂载 FAT 引导分区 (p3) =="
LOOP=$(losetup --find --show -o $((32768*512)) --sizelimit $((202752*512)) "$OUT")
MNT=/mnt/ngp_fat; mkdir -p "$MNT"
mount -t vfat "$LOOP" "$MNT"
trap 'umount "$MNT" 2>/dev/null || true; losetup -d "$LOOP" 2>/dev/null || true' EXIT

echo "== 4. 放入新内核 / DTB / extlinux =="
cp "$K/arch/arm64/boot/Image" "$MNT/Image"
cp "$W/rk3562-ngp45ht.dtb" "$MNT/rk3562-ngp45ht.dtb"
cp "$W/extlinux_ngp.conf" "$MNT/extlinux/extlinux.conf"
sync
echo "   分区内容:"
ls -la "$MNT" "$MNT/extlinux"
echo "   extlinux.conf:"
cat "$MNT/extlinux/extlinux.conf"

echo "== 5. 校验扇区写入结果 =="
umount "$MNT"; losetup -d "$LOOP"; trap - EXIT
python3 - "$OUT" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb')
f.seek(512*64); h = f.read(4)
print("  idbloader 头  :", h.hex(), "(期望 a540b9fe = RK 签名)")
f.seek(512*16384); print("  uboot FIT 魔数:", f.read(4).hex(), "(期望 d00dfeed)")
f.seek(512*32768); b = f.read(8192)
print("  FAT 引导标志  :", "合法" if b[54:56] in (b'FAT', b'MSW') and b[0] == 0xEB else "?", b[54:62])
PY

echo "== 6. 打包 tar.gz (稀疏文件不适合分发) =="
tar czf /root/ngp/out/$(basename "$OUT").tar.gz -C /root/ngp/out $(basename "$OUT")
ls -la /root/ngp/out/$(basename "$OUT").tar.gz
echo "ALL_DONE"
