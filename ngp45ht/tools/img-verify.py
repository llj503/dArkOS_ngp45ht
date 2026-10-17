#!/usr/bin/env python3
# Structural verification of an assembled image: GPT both copies, the three
# readable partitions, the bootloader images in p1/p2.
import sys, os, hashlib, struct, uuid

IMG = sys.argv[1] if len(sys.argv) > 1 else r'E:\darkos\work\release\dArkOS_ngp45ht_trixie_20261017.img'
f = open(IMG, 'rb', buffering=0)
SIZE = os.path.getsize(IMG)

def rd(off, n):
    f.seek(off); b = f.read(n)
    assert len(b) == n, 'short read at %d' % off
    return b

print('file      :', IMG)
print('size      : %d bytes (%.2f GiB)  %s' %
      (SIZE, SIZE / 1073741824.0, 'OK' if SIZE == 12884901888 else 'UNEXPECTED'))

print()
print('== primary GPT @512 ==')
gpt = rd(512, 92)
sig, rev, hdr_sz, crc, _res, cur, bak, first_usable, last_usable, disk_guid, pt_start, n_ent, ent_sz, p_crc = \
    struct.unpack('<8sIIIIQQQQ16sQIII', gpt)
print('  signature        : %s  %s' % (sig.decode(), 'OK' if sig == b'EFI PART' else 'BAD'))
print('  revision         : %d.%d' % (rev >> 16, rev & 0xFFFF))
print('  header size      : %d   entries: %d x %d' % (hdr_sz, n_ent, ent_sz))
print('  my LBA / backup  : %d / %d' % (cur, bak))
print('  first/last usable: %d / %d' % (first_usable, last_usable))
print('  disk GUID        : %s' % str(uuid.UUID(bytes_le=disk_guid)).upper())
print('  PartitionEntryLBA: %d  (header CRC32 %08x, array CRC32 %08x)' % (pt_start, crc, p_crc))
# verify CRCs ourselves
crc_calc = 0xFFFFFFFF
zeroed = bytearray(rd(512, hdr_sz)); zeroed[16:20] = b'\0\0\0\0'
import zlib
print('  header CRC32 recompute : %08x  %s' % (zlib.crc32(bytes(zeroed)) & 0xFFFFFFFF,
      'OK' if (zlib.crc32(bytes(zeroed)) & 0xFFFFFFFF) == crc else 'MISMATCH'))
arr = rd(pt_start * 512, n_ent * ent_sz)
print('  array  CRC32 recompute : %08x  %s' % (zlib.crc32(arr) & 0xFFFFFFFF,
      'OK' if (zlib.crc32(arr) & 0xFFFFFFFF) == p_crc else 'MISMATCH'))

names = []
for i in range(n_ent):
    e = arr[i * ent_sz:(i + 1) * ent_sz]
    if e[0:16] == b'\0' * 16:
        continue
    tg = e[0:16]
    fs, fe, attr = struct.unpack_from('<QQQ', e, 32)
    name = e[56:128].decode('utf-16-le').rstrip('\0')
    names.append((i + 1, name, fs * 512, (fe - fs + 1) * 512, fe))
print()
print('== partition table ==')
print('  #  %-14s %14s %14s' % ('name', 'start (B)', 'size (B)'))
for n, name, s, sz, fe in names:
    print('  %-2d %-14s %14d %14d' % (n, name, s, sz))
largest_end = max(n[4] for n in names)
print('  last used LBA %d vs last usable %d -> %s' %
      (largest_end, last_usable, 'OK' if largest_end <= last_usable else 'OVERRUN'))

print()
print('== bootloader sprites (p1/p2 region) ==')
rb = rd(64 * 512, 4)
print('  idbloader magic @sector 64 : %s  %s' % (rb, 'OK' if rb == b'RKNS' else 'BAD'))
found = None
for add in range(8 * 1024 * 1024, 12 * 1024 * 1024, 64 * 1024):
    if rd(add, 4) == bytes.fromhex('d00dfeed'):
        found = add; break
print('  u-boot FIT @0x%x           : %s' % (found or 0, 'OK' if found else 'NOT FOUND'))

print()
print('== p3 dArkOS_Fat @16777216 ==')
b = rd(16777216, 512)
print('  FS type / label  : %r / %r' % (b[82:88], b[71:82]))
print('  total_sectors32  : %d  (= %d bytes readable)' % (struct.unpack_from('<I', b, 32)[0],
      struct.unpack_from('<I', b, 32)[0] * 512))

print()
print('== p4 rootfs btrfs @121634816 ==')
sb = rd(121634816 + 65536, 4096)
print('  magic            : %s  %s' % (sb[64:72], 'OK' if sb[64:72] == b'_BHRfS_M' else 'BAD'))
tb = int.from_bytes(sb[0x70:0x78], 'little')
lbl = sb[0x12b:0x12b + 32].rstrip(b'\0').decode('utf-8', 'replace')
print('  total_bytes      : %d  (partition 12629049344) %s' % (tb, 'MATCH' if tb == 12629049344 else 'MISMATCH'))
print('  label            : %r' % lbl)

print()
print('== tail: p5 + backup GPT ==')
t_off = 12750684160
b5 = rd(t_off, 512)
print('  p5 FS type/label : %r / %r' % (b5[54:59], b5[43:47]))
bgpt = rd(SIZE - 512, 92)
print('  backup GPT magic : %s  %s' % (bgpt[0:8], 'OK' if bgpt[0:8] == b'EFI PART' else 'BAD'))
print('  backup myLBA     : %d (expect %d)' % (struct.unpack_from('<Q', bgpt, 24)[0], SIZE // 512 - 1))

print()
# final full-file hash is computed separately; print a cheap tail check
print('overall size/structure check complete.')
f.close()
