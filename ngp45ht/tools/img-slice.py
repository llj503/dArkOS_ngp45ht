#!/usr/bin/env python3
# Cut the pieces we cannot read off the card (there is no \\.\Volume path for
# p1/p2, and p5 on the card has already been expanded by firstboot) out of the
# previously assembled image, and sanity-check each one.
#   img-slice.py [previous.img] [outdir]
# Cut the pieces that cannot be read off the card out of the previous image
# and sanity-check them.  There is no \\.\Volume path for p1/p2, and p5 on a
# used card has already been expanded by firstboot, so both come from here.
import os, hashlib, struct, sys

HERE = os.path.dirname(os.path.abspath(__file__)) if len(sys.argv) < 2 else None
OLD  = sys.argv[1] if len(sys.argv) > 1 else r'E:\darkos\work\release\dArkOS_ngp45ht_trixie_20261017.img'
HERE = sys.argv[2] if len(sys.argv) > 2 else os.path.dirname(os.path.abspath(OLD))
P3   = r'\\.\Volume{8d14d6ba-fe8d-4971-a653-058337b876fb}'   # dArkOS_Fat  (check mountvol!)
P4   = r'\\.\Volume{14a2f32a-21f1-4513-8bb8-1066c69cea6f}'   # btrfs ROOTFS

PREFIX_END  = 16777216            # 16 MiB
P3_LEN      = 103799808           # what the FAT32 BPB claims
P3_PART     = 103809024           # what GPT says the partition is
GAP         = 1048576
P4_OFF      = 121634816
P4_LEN      = 12629049344
TAIL_OFF    = P4_OFF + P4_LEN     # 12750684160
TOTAL       = 12884901888

def slice_out(src, off, size, dst):
    f = open(src, 'rb', buffering=0); f.seek(off)
    h = hashlib.sha256(); remain = size
    o = open(dst, 'wb', buffering=0)
    while remain:
        b = f.read(min(8 * 1024 * 1024, remain))
        if not b: raise IOError('short read from %s at %d' % (src, off + size - remain))
        o.write(b); h.update(b); remain -= len(b)
    o.close(); f.close()
    return h.hexdigest()

print('extracting from', OLD)
h1 = slice_out(OLD, 0,          PREFIX_END,                    os.path.join(HERE, 'prefix16.bin'))
print('  prefix16.bin      %d  sha256 %s' % (PREFIX_END, h1[:16]))
h2 = slice_out(OLD, PREFIX_END + P3_LEN, P3_PART - P3_LEN,       os.path.join(HERE, 'p3_slack9216.bin'))
# ^ NB: PREFIX_END + P3_LEN == 120577024.  Offsetting this from PREFIX_END alone
# pulls the first 9216 bytes of the *partition* (its boot sector) instead of the
# trailing slack, which silently corrupts 9216 bytes of the assembled image.
# The correct slack is all zeros; checksum it against the compare script.
print('  p3_slack9216.bin  %d  sha256 %s  (all-zero: %s)'
      % (P3_PART - P3_LEN, h2[:16],
         open(os.path.join(HERE, 'p3_slack9216.bin'), 'rb').read() == b'\0' * (P3_PART - P3_LEN)))
h3 = slice_out(OLD, PREFIX_END + P3_PART, GAP,                 os.path.join(HERE, 'gap1m.bin'))
gap = open(os.path.join(HERE, 'gap1m.bin'), 'rb').read()
print('  gap1m.bin         %d  all-zero: %s' % (GAP, set(gap) == {0}))
h4 = slice_out(OLD, TAIL_OFF,   TOTAL - TAIL_OFF,              os.path.join(HERE, 'tail128.bin'))
print('  tail128.bin       %d  sha256 %s' % (TOTAL - TAIL_OFF, h4[:16]))

print()
print('sanity checks on the pieces:')
p = open(os.path.join(HERE, 'prefix16.bin'), 'rb').read()
print('  GPT header magic at 512      :', p[512:520] == b'EFI PART')
print('  idbloader RKNS at sector 64  :', p[64 * 512:64 * 512 + 4] == b'RKNS')
t = open(os.path.join(HERE, 'tail128.bin'), 'rb').read()
print('  backup GPT magic near end    :', t[-512:-504] == b'EFI PART')
print('  p5 start is FAT16 "ROMS"     :', t[54:59] == b'FAT16', t[43:47])

print()
print('live card:')
f = open(P3, 'rb', buffering=0); f.seek(0); b = f.read(512)
tot32 = struct.unpack_from('<I', b, 32)[0]
tot16 = struct.unpack_from('<H', b, 19)[0]
sec_per_fat = struct.unpack_from('<I', b, 36)[0]
print('  p3 BPB total_sectors32 = %d  (16-bit field = %d, unused)' % (tot32, tot16))
print('  expected readable length = %d bytes' % (tot32 * 512))
print('  gap to GPT partition size  = %d bytes' % (P3_PART - tot32 * 512))
f4 = open(P4, 'rb', buffering=0); f4.seek(65536); sb = f4.read(4096)
print('  p4 btrfs magic            :', sb[64:72] == b'_BHRfS_M')
tb = int.from_bytes(sb[0x70:0x78], 'little')
import uuid
print('  p4 total_bytes            = %d  (partition %d)  %s'
      % (tb, P4_LEN, 'MATCH' if tb == P4_LEN else 'MISMATCH'))
