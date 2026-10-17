#!/usr/bin/env python3
# Compare the freshly cloned image against the previous one, region by region,
# so we can show *what* actually changed - and confirm the parts we cannot read
# off the card (GPT/bootloader prefix, alignment gap, tail with p5 + backup GPT)
# came through untouched.
#   img-compare.py previous.img new.img
import os, hashlib, sys

HERE = r'E:\darkos\work\release'
A = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'dArkOS_ngp45ht_trixie_20261017.img')
B = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, 'dArkOS_ngp45ht_trixie_20261017.new.img')

REGIONS = [
    (0,            16777216,     'p1/p2 bootloader + GPT'),
    (16777216,     103799808,    'p3 dArkOS_Fat (readable)'),
    (120577024,    9216,         'p3 slack'),
    (120586240,    1048576,      'alignment gap'),
    (121634816,    12629049344,  'p4 rootfs (btrfs)'),
    (12750684160,  134217728,    'p5 + backup GPT (tail)'),
]

def sha(fh, size):
    h = hashlib.sha256(); remain = size
    while remain:
        b = fh.read(min(8 * 1024 * 1024, remain))
        if not b: raise IOError('unexpected EOF')
        h.update(b); remain -= len(b)
    return h.hexdigest()

if not os.path.exists(B):
    sys.exit('missing %s' % B)

print('%-28s %-64s %-64s %s' % ('region', 'previous', 'new', 'same?'))
print('-' * 170)
fa = open(A, 'rb', buffering=0)
fb = open(B, 'rb', buffering=0)
diffs = []
for off, size, label in REGIONS:
    fa.seek(off); ha = sha(fa, size)
    fb.seek(off); hb = sha(fb, size)
    same = ha == hb
    if not same: diffs.append((off, size, label))
    print('%-28s %s  %s  %s' % (label, ha[:64], hb[:64], 'same' if same else 'DIFFERENT'))
fa.close(); fb.close()

# count how much of p4 differs, at 8 MiB granularity, and where the first/last
# difference lands - a cheap locality report for the release notes
if diffs:
    print()
    print('change locality inside p4 (%d bytes):' % 12629049344)
    fa = open(A, 'rb', buffering=0); fb = open(B, 'rb', buffering=0)
    step = 8 * 1024 * 1024
    base = 121634816
    ndiff = ntot = 0
    first = last = None
    for i in range(12629049344 // step):
        fa.seek(base + i * step); a = fa.read(step)
        fb.seek(base + i * step); b = fb.read(step)
        ntot += 1
        if a != b:
            ndiff += 1
            if first is None: first = i * step
            last = i * step
    fa.close(); fb.close()
    print('  %d / %d 8 MiB blocks differ (%.1f%% of the partition)' % (ndiff, ntot, 100.0 * ndiff / ntot))
    if first is not None:
        print('  first difference at p4+%d (%.2f GiB), last at p4+%d (%.2f GiB)'
              % (first, first / 1073741824.0, last, last / 1073741824.0))

print()
print('regions that changed:', [d[2] for d in diffs] or 'none')
