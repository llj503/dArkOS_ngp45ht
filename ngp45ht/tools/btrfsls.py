#!/usr/bin/env python3
# btrfsls.py -- read-only offline path listing of a btrfs filesystem.
#
# Why this exists:  the NGP45HT rootfs is btrfs with compress=zstd:1, so small
# files (NetworkManager connection profiles, .VERSION) live inside compressed
# extents and a plaintext grep over the partition silently finds nothing -- that
# false negative is exactly how a WiFi psk once slipped into a published image.
# File *names*, however, are stored in B-tree leaves, and metadata is never
# compressed, so walking the leaves gives a trustworthy listing without ever
# mounting the filesystem (Windows cannot mount btrfs; WSL is unavailable here).
#
# IMPORTANT -- walk, do not sweep:
#   An earlier version of this tool swept every *physical* metadata block.  That
#   also picks up leaves that were COW-replaced and are now free space, so
#   deleted files reappear as if they still existed.  That stale view produced
#   two wrong conclusions (a phantom enabled firstboot.service symlink and a
#   superseded /etc/fstab).  The default now walks the *current* B-tree from
#   each live tree root found in the root tree's ROOT_ITEMs.  `--sweep` keeps
#   the old behaviour for archaeology.
#
# Usage:
#   btrfsls.py <volume-or-image> [offset] [--grep substr] [--count]
#              [--names-only] [--mtimes] [--trees]
#              [--cat PATH] [--stat PATH] [--sweep]
import sys, os, struct, argparse

MAGIC = b'_BHRfS_M'
SUPER_OFF = 0x10000
# btrfs_super_block.sys_chunk_array[] -- verified against this very image: with
# sys_chunk_array_size=97 and one DUP entry, the first (256, CHUNK_ITEM, ...) key
# sits at superblock offset 0x32b.  (0x425, often quoted, is wrong here.)
SYS_CHUNK_OFF = 0x32B
BTRFS_CHUNK_ITEM = 228
BTRFS_DIR_ITEM, BTRFS_DIR_INDEX = 84, 150
BTRFS_INODE_REF, BTRFS_INODE_EXTREF = 12, 14
BTRFS_INODE_ITEM, BTRFS_EXTENT_DATA = 1, 108
BTRFS_ROOT_ITEM = 132
BLOCK_GROUP_METADATA = 1 << 2
BLOCK_GROUP_SYSTEM = 1 << 1


class Map:
    """logical -> physical translation built from the chunk tree."""
    def __init__(self):
        self.ranges = []          # (logical_start, length, physical_start, flags)

    def add(self, logical, length, physical, flags=0):
        self.ranges.append((logical, length, physical, flags))

    def sort(self):
        self.ranges.sort()

    def phys(self, logical):
        for ls, ln, ps, _f in self.ranges:
            if ls <= logical < ls + ln:
                return ps + (logical - ls)
        return None

    def meta_ranges(self):
        return [(ls, ln, ps) for ls, ln, ps, f in self.ranges
                if f & (BLOCK_GROUP_METADATA | BLOCK_GROUP_SYSTEM)]


class Btrfs:
    def __init__(self, fh, base, sectorsize=512):
        self.fh = fh
        self.base = base
        self.ss = sectorsize

    def read(self, off, length):
        self.fh.seek(self.base + off)
        return self.fh.read(length)

    def logical(self, addr, length):
        p = self.map.phys(addr)
        if p is None:
            raise IOError('unmapped logical 0x%x' % addr)
        if p % self.ss:
            raise IOError('unaligned physical 0x%x' % p)
        return self.read(p, length)


def parse_super(vol):
    buf = vol.read(SUPER_OFF, 4096)
    if buf[0x40:0x48] != MAGIC:
        raise SystemExit('no btrfs superblock at 0x%x (got %r)' % (SUPER_OFF, buf[0x40:0x48]))
    s = {}
    for k, off, fmt in (('bytenr', 0x30, '<Q'), ('flags', 0x38, '<Q'),
                        ('generation', 0x48, '<Q'), ('root', 0x50, '<Q'),
                        ('chunk_root', 0x58, '<Q'), ('log_root', 0x60, '<Q'),
                        ('total_bytes', 0x70, '<Q'), ('bytes_used', 0x78, '<Q'),
                        ('root_dir_objectid', 0x80, '<Q'), ('num_devices', 0x88, '<Q')):
        s[k] = struct.unpack_from(fmt, buf, off)[0]
    s['sectorsize'], s['nodesize'] = struct.unpack_from('<II', buf, 0x90)
    s['sys_chunk_array_size'] = struct.unpack_from('<I', buf, 0xA0)[0]
    s['label'] = buf[0x12B:0x12B + 256].split(b'\0')[0].decode('utf-8', 'replace')
    s['incompat'] = struct.unpack_from('<Q', buf, 0xBC)[0]
    return s


def parse_chunk_array(vol, buf, off, size, out):
    """sys_chunk_array[] holds raw btrfs_disk_key + btrfs_chunk pairs."""
    end = off + size
    while off + 17 <= end:
        objectid, ctype, keyoff = struct.unpack_from('<QBQ', buf, off)
        off += 17
        if ctype != BTRFS_CHUNK_ITEM:
            break
        (length, owner, stripe_len, ctype_flags, io_align, io_width,
         sector_size, num_stripes, sub_stripes) = struct.unpack_from('<QQQQIIIHH', buf, off)
        stripe0 = off + 48          # struct btrfs_chunk is 48 bytes + stripes
        devid, physical = struct.unpack_from('<QQ', buf, stripe0)
        out.add(keyoff, length, physical, BLOCK_GROUP_SYSTEM)
        off += 48 + 32 * num_stripes


def walk_tree(vol, addr, leaf_cb, depth=0, seen=None):
    """Depth-first walk; leaf_cb(leaf_buf, owner) is called for every leaf."""
    if seen is None:
        seen = set()
    if addr in seen or depth > 16:
        return
    seen.add(addr)
    try:
        buf = vol.logical(addr, vol.nodesize)
    except IOError as e:
        sys.stderr.write('  ! %s\n' % e)
        return
    nritems, level = struct.unpack_from('<I', buf, 96)[0], buf[100]
    owner = struct.unpack_from('<Q', buf, 88)[0]
    if level == 0:
        leaf_cb(buf, owner)
        return
    # Internal nodes hold btrfs_key_ptr[33] (key[17] + blockptr[8] + gen[8]),
    # NOT btrfs_item[25] -- using the leaf stride here silently produced
    # garbage block pointers and the whole walk collapsed at the tree root.
    for i in range(nritems):
        o = 101 + 33 * i
        blockptr = struct.unpack_from('<Q', buf, o + 17)[0]
        walk_tree(vol, blockptr, leaf_cb, depth + 1, seen)


def items(buf):
    nritems = struct.unpack_from('<I', buf, 96)[0]
    for i in range(nritems):
        oid, ty, keyoff, data_off, size = struct.unpack_from('<QBQII', buf, 101 + 25 * i)
        yield oid, ty, keyoff, buf[101 + data_off:101 + data_off + size]


def find_roots(vol, sup):
    """Live FS trees, read from the root tree's ROOT_ITEMs.

    struct btrfs_root_item: inode_item[160] | generation@160 | root_dirid@168 |
    bytenr@176 | ... | drop_progress@220[17] | drop_level@237 | level@238.
    Only ROOT_ITEMs with a non-zero bytenr describe a tree we can walk.
    """
    roots = []

    def on_leaf(buf, owner):
        for oid, ty, keyoff, d in items(buf):
            if ty != BTRFS_ROOT_ITEM or len(d) < 244:
                continue
            bytenr = struct.unpack_from('<Q', d, 176)[0]
            if not bytenr:
                continue
            # Only file trees carry names: FS_TREE (5) and subvolumes (>=256).
            # 2=extent 3=chunk 4=dev 7=csum 9=uuid and -9=data-reloc are skipped
            # on purpose -- the data reloc tree in particular still pointed at
            # files from an old balance and would resurrect them as phantoms.
            if not (oid == 5 or 256 <= oid <= (1 << 62)):
                continue
            roots.append({
                'id': oid,
                'bytenr': bytenr,
                'dirid': struct.unpack_from('<Q', d, 168)[0],
                'gen': struct.unpack_from('<Q', d, 160)[0],
                'level': d[238],
            })

    walk_tree(vol, sup['root'], on_leaf)
    roots.sort(key=lambda r: r['id'])
    return roots


def make_walker(vol, cmap, roots):
    """Return cb -> None that feeds every *current* leaf to cb."""
    def sweep(cb):
        for r in roots:
            walk_tree(vol, r['bytenr'], cb)
    return sweep


def make_physical_sweeper(vol, cmap):
    """Old behaviour: every metadata block, including stale COW-replaced ones."""
    def sweep(cb):
        for ls, ln, ps in cmap.meta_ranges():
            off = 0
            while off < ln:
                blk = min(8 << 20, ln - off)
                data = vol.read(ps + off, blk)
                for p in range(0, blk - vol.nodesize + 1, vol.nodesize):
                    b = data[p:p + vol.nodesize]
                    if b[32:48] == b'\0' * 16 or b[100] != 0:
                        continue
                    try:
                        nritems = struct.unpack_from('<I', b, 96)[0]
                    except Exception:
                        continue
                    if nritems == 0 or nritems > 1000:
                        continue
                    cb(b, struct.unpack_from('<Q', b, 88)[0])
                off += blk
    return sweep


def resolve(sweep, wanted):
    """Walk `wanted` components down from each tree's root dir."""
    children = {}

    def build(buf, owner):
        for oid, ty, keyoff, d in items(buf):
            if ty == BTRFS_DIR_ITEM or ty == BTRFS_DIR_INDEX:
                q = 0
                while q + 30 <= len(d):
                    child = struct.unpack_from('<Q', d, q)[0]
                    dlen, nlen = struct.unpack_from('<HH', d, q + 25)
                    name = d[q + 30:q + 30 + nlen]
                    if nlen:
                        children.setdefault((owner, oid), set()).add((name, child))
                    q += 30 + nlen + dlen

    sweep(build)
    comps = [c.encode() for c in wanted.strip('/').split('/') if c]
    hits = []
    for owner in sorted({o for o, _ in children}):
        for root in sorted({256, 6} | {r['dirid'] for r in []}):
            pass
        for root in (256, 6):          # FS-tree subvol dir / top-level tree dir
            inum, ok = root, True
            for comp in comps:
                nxt = [c for n, c in children.get((owner, inum), ()) if n == comp]
                if not nxt:
                    ok = False
                    break
                inum = nxt[0]
            if ok:
                hits.append((owner, inum))
                break
    return hits


def stat_path(vol, cmap, path, sweep):
    """mtime/size/owner of a path -- the only clock we have offline, and enough
    to tell "written during this boot" from "came with the image"."""
    import datetime
    hits = resolve(sweep, path)
    if not hits:
        print('%-46s  (no such path)' % path)
        return
    owner, inum = hits[0]
    found = {}

    def grab(buf, own):
        if own != owner:
            return
        for oid, ty, keyoff, d in items(buf):
            if oid == inum and ty == BTRFS_INODE_ITEM and len(d) >= 148:
                found['d'] = d

    sweep(grab)
    d = found.get('d')
    if not d:
        print('%-46s  (no inode item)' % path)
        return
    size = struct.unpack_from('<Q', d, 16)[0]
    uid, gid, mode = struct.unpack_from('<III', d, 44)
    mtime = struct.unpack_from('<Q', d, 136)[0]   # timespec at 112/124/136/148
    print('%-46s %9d  %s  %o  uid=%d gid=%d' % (
        path, size,
        datetime.datetime.fromtimestamp(mtime).strftime('%Y-%m-%d %H:%M:%S') if mtime else '-',
        mode, uid, gid))


def cat_file(vol, cmap, path, sweep):
    """Read one file's contents out of the filesystem without mounting it.

    Two passes: resolve the path down to an inode (per FS-tree id, since
    objectids are only unique inside a tree), then look for that inode's
    EXTENT_DATA items and reassemble them, decompressing zstd inline/regular
    extents as needed.
    """
    import zstandard
    hits = resolve(sweep, path)
    if not hits:
        raise SystemExit('no such path: %s' % path)
    owner, inum = hits[0]

    extents = {}

    def grab(buf, own):
        if own != owner:
            return
        for oid, ty, keyoff, d in items(buf):
            if oid == inum and ty == BTRFS_EXTENT_DATA:
                extents[keyoff] = d
            elif oid == inum and ty == BTRFS_INODE_ITEM and len(d) >= 24:
                extents['size'] = struct.unpack_from('<Q', d, 16)[0]

    sweep(grab)
    size = extents.pop('size', None)

    out = bytearray()
    dctx = zstandard.ZstdDecompressor()

    def dzstd(raw):
        # btrfs stores zstd *blocks*, not self-describing frames: there is no
        # content size in the frame header, so decompress() needs a bound.
        for bound in (1 << 20, 16 << 20, 128 << 20):
            try:
                return dctx.decompress(raw, max_output_size=bound)
            except zstandard.ZstdError:
                continue
        raise SystemExit('zstd: could not decompress %d bytes' % len(raw))

    for off in sorted(extents):
        d = extents[off]
        # btrfs_file_extent_item: generation(0) ram_bytes(8) compression:u8(16)
        # encryption:u8(17) other_encoding:u16(18) type:u8(20) disk_bytenr(21)
        # disk_num_bytes(29) offset(37) num_bytes(45).  Inline data starts at
        # the offset of disk_bytenr, i.e. 21.
        ram = struct.unpack_from('<Q', d, 8)[0]
        comp = d[16]
        etype = d[20]
        if etype == 0:                            # inline: data starts at 21
            raw = d[21:]
            out += dzstd(raw) if comp else raw
            continue
        dbn, dbnum, eoff, nbytes = struct.unpack_from('<QQQQ', d, 21)
        if dbn == 0:                              # hole / prealloc
            out += b'\0' * nbytes
            continue
        phys = cmap.phys(dbn)
        if phys is None:
            raise SystemExit('unmapped extent 0x%x' % dbn)
        if comp:
            buf = dzstd(vol.read(phys, dbnum))
            out += buf[eoff:eoff + nbytes]
        else:
            out += vol.read(phys + eoff, nbytes)
    if size is not None:
        out = out[:size]
    sys.stderr.write('%s: %d bytes (inode %d in tree %d)\n' % (path, len(out), inum, owner))
    return bytes(out)


def collect(vol, cmap, sweep):
    children = {}      # (owner, parent_inum) -> [(name, child_inum, ftype)]
    parents = {}       # (owner, child_inum)  -> (parent_inum, name)
    inodes = {}        # (owner, inum) -> (size, mtime)

    def cb(b, own):
        for oid, ty, keyoff, d in items(b):
            if ty == BTRFS_DIR_ITEM or ty == BTRFS_DIR_INDEX:
                q = 0
                while q + 30 <= len(d):
                    child = struct.unpack_from('<Q', d, q)[0]
                    dlen, nlen = struct.unpack_from('<HH', d, q + 25)
                    ftype = d[q + 29]
                    name = d[q + 30:q + 30 + nlen]
                    if nlen:
                        children.setdefault((own, oid), []).append((name, child, ftype))
                    q += 30 + nlen + dlen
            elif ty == BTRFS_INODE_REF:
                q = 0
                while q + 10 <= len(d):
                    nlen = struct.unpack_from('<H', d, q + 8)[0]
                    name = d[q + 10:q + 10 + nlen]
                    if nlen:
                        parents[(own, oid)] = (keyoff, name)
                    q += 10 + nlen
            elif ty == BTRFS_INODE_EXTREF:
                q = 0
                while q + 18 <= len(d):
                    poid = struct.unpack_from('<Q', d, q)[0]
                    nlen = struct.unpack_from('<H', d, q + 16)[0]
                    name = d[q + 18:q + 18 + nlen]
                    if nlen:
                        parents[(own, oid)] = (poid, name)
                    q += 18 + nlen
            elif ty == BTRFS_INODE_ITEM and len(d) >= 148:
                inodes[(own, oid)] = (struct.unpack_from('<Q', d, 16)[0],
                                      struct.unpack_from('<Q', d, 136)[0])
    sweep(cb)
    return children, parents, inodes


def build_map(vol, sup):
    cmap = Map()
    parse_chunk_array(vol, vol.read(SUPER_OFF, 4096), SYS_CHUNK_OFF,
                      sup['sys_chunk_array_size'], cmap)
    cmap.sort()
    vol.map = cmap
    vol.nodesize = sup['nodesize']

    def on_leaf(buf, owner):
        for oid, ty, keyoff, d in items(buf):
            if ty == BTRFS_CHUNK_ITEM:
                length, owner_, slen, flags, ia, iw, ss, ns, subs = struct.unpack_from('<QQQQIIIHH', d, 0)
                devid, physical = struct.unpack_from('<QQ', d, 48)
                cmap.add(keyoff, length, physical, flags)

    walk_tree(vol, sup['chunk_root'], on_leaf)
    cmap.sort()
    return cmap


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('target')
    ap.add_argument('offset', nargs='?', type=lambda x: int(x, 0), default=0)
    ap.add_argument('--grep', default=None)
    ap.add_argument('--count', action='store_true')
    ap.add_argument('--names-only', action='store_true')
    ap.add_argument('--cat', default=None, metavar='PATH')
    ap.add_argument('--stat', default=None, metavar='PATH')
    ap.add_argument('--mtimes', action='store_true')
    ap.add_argument('--trees', action='store_true')
    ap.add_argument('--sweep', action='store_true',
                    help='(archaeology) scan every physical metadata block, '
                         'including stale COW-replaced leaves')
    a = ap.parse_args()

    fh = open(a.target, 'rb')
    vol = Btrfs(fh, a.offset)
    sup = parse_super(vol)
    sys.stderr.write('label=%r nodesize=%d sectorsize=%d total_bytes=%d (%.2f GiB) incompat=0x%x\n'
                     % (sup['label'], sup['nodesize'], sup['sectorsize'], sup['total_bytes'],
                        sup['total_bytes'] / 2**30, sup['incompat']))
    cmap = build_map(vol, sup)
    sys.stderr.write('chunks: %d, %.1f MiB mapped\n'
                     % (len(cmap.ranges), sum(l for _, l, _, _ in cmap.ranges) / 2**20))

    roots = find_roots(vol, sup)
    sys.stderr.write('live trees: %s\n' % ', '.join('%d@0x%x' % (r['id'], r['bytenr']) for r in roots))
    if a.trees:
        for r in roots:
            print('tree %-6d bytenr=0x%-10x gen=%-8d level=%d rootdir=%d'
                  % (r['id'], r['bytenr'], r['gen'], r['level'], r['dirid']))
        return

    sweep = (make_physical_sweeper(vol, cmap) if a.sweep
             else make_walker(vol, cmap, roots))
    if a.sweep:
        sys.stderr.write('WARNING: --sweep reports deleted files too\n')

    if a.stat:
        stat_path(vol, cmap, a.stat, sweep)
        return

    if a.cat:
        sys.stdout.buffer.write(cat_file(vol, cmap, a.cat, sweep))
        return

    children, parents, inodes = collect(vol, cmap, sweep)
    sys.stderr.write('dirs=%d  parent-links=%d  inodes=%d\n'
                     % (len(children), len(parents), len(inodes)))

    def path_of(key):
        own, inum = key
        parts = []
        seen = set()
        while key in parents and key not in seen:
            seen.add(key)
            p, name = parents[key]
            parts.append(name)
            key = (own, p)
        return b'/'.join(reversed(parts))

    out = []
    seen_paths = set()
    for parent, ents in children.items():
        own = parent[0]
        base = path_of(parent)
        for name, child, ftype in ents:
            p = (base + b'/' + name) if base else b'/' + name
            # DIR_ITEM and DIR_INDEX both describe the same entry, so dedupe.
            k = (p, child)
            if k in seen_paths:
                continue
            seen_paths.add(k)
            out.append((p, own, child, ftype, inodes.get((own, child))))
    out.sort(key=lambda t: (t[1], t[0]))
    if a.mtimes:
        import datetime
        for p, own, child, ftype, ino in out:
            size, mt = ino if ino else (0, 0)
            print('%s\t%d\t%s' % (
                datetime.datetime.fromtimestamp(mt).strftime('%Y-%m-%d %H:%M:%S') if mt else '-',
                size, p.decode('utf-8', 'replace')))
        sys.stderr.write('total=%d\n' % len(out))
        return
    if a.names_only:
        for p, own, child, ftype, ino in out:
            print(p.decode('utf-8', 'replace'))
        sys.stderr.write('total=%d\n' % len(out))
        return
    n = 0
    for p, own, child, ftype, ino in out:
        s = p.decode('utf-8', 'replace')
        if a.grep and a.grep not in s:
            continue
        n += 1
        if not a.count:
            print('%s%s' % (s, '/' if ftype == 2 else ''))
    sys.stderr.write('matched=%d total=%d\n' % (n, len(out)))


if __name__ == '__main__':
    main()
