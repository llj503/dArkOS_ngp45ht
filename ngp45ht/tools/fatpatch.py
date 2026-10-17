"""List / patch files inside partition 3's FAT32 of the deliverable image.

Everything is derived from the on-disk layout; writes stay inside p3's bytes.
Usage:  python fatpatch.py list
        python fatpatch.py patch <name> <source-file>
        python fatpatch.py extract <name> <dest-file>
"""
import struct, os, sys

IMG = os.environ.get("NGP_IMG", r"F:\darkos\dArkOS_ngp45ht_trixie_20261013.img")
P3_OFF, P3_SIZE = 16777216, 103809024
EOF32 = 0x0FFFFFF8


class Fat32:
    def __init__(self, writable=False):
        self.f = open(IMG, "r+b" if writable else "rb")
        self.f.seek(P3_OFF)
        b = self.f.read(512)
        assert b[510:512] == b"\x55\xaa", "p3 起始不是 FAT 引导扇区"
        self.spc = b[13]
        self.res = struct.unpack("<H", b[14:16])[0]
        self.nf = b[16]
        self.fatsz = struct.unpack("<I", b[36:40])[0]
        self.rootcl = struct.unpack("<I", b[44:48])[0]
        self.cs = 512 * self.spc
        self.data = P3_OFF + (self.res + self.nf * self.fatsz) * 512
        self.fat0 = P3_OFF + self.res * 512

    def entry(self, cl):
        self.f.seek(self.fat0 + cl * 4)
        return struct.unpack("<I", self.f.read(4))[0] & 0x0FFFFFFF

    def set_entry(self, cl, val):
        for k in range(self.nf):
            self.f.seek(self.fat0 + k * self.fatsz * 512 + cl * 4)
            self.f.write(struct.pack("<I", val))

    def chain(self, cl):
        out = []
        while cl < EOF32:
            out.append(cl)
            cl = self.entry(cl)
            if len(out) > 300000:
                raise SystemExit("FAT 链疑似成环")
        return out

    def cl_off(self, cl):
        return self.data + (cl - 2) * self.cs

    def root_bytes(self):
        raw = b""
        cl = self.rootcl
        while cl < EOF32:
            self.f.seek(self.cl_off(cl))
            raw += self.f.read(self.cs)
            cl = self.entry(cl)
        return raw

    def dirlist(self):
        """Root directory entries.  The directory may span non-contiguous
        clusters, so a global byte index has to be mapped through the chain."""
        cl = self.rootcl
        raw = b""
        while cl < EOF32:
            self.f.seek(self.cl_off(cl))
            raw += self.f.read(self.cs)
            cl = self.entry(cl)
        out, lfn = [], []
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if e[0] == 0:
                break
            if e[11] == 0x0F:
                lfn.append((e[0] & 0x3F, e[1:11] + e[14:26] + e[28:32]))
                continue
            if e[0] == 0xE5:
                continue
            nm = (b"".join(x[1] for x in sorted(lfn)).decode("utf-16-le", "replace").split("\0")[0]
                  if lfn else
                  e[:8].decode("latin-1").rstrip() +
                  ("." + e[8:11].decode("latin-1").rstrip(". ") if e[8] != 32 else ""))
            hi, lo = struct.unpack("<H", e[20:22])[0], struct.unpack("<H", e[26:28])[0]
            out.append({"name": nm, "size": struct.unpack("<I", e[28:32])[0],
                        "cl": (hi << 16) | lo, "off": self.dir_off(i), "attr": e[11]})
            lfn = []
        return out

    def dir_off(self, index):
        """Absolute file offset of byte @index inside the root directory."""
        chain = self.chain(self.rootcl)
        k, rem = divmod(index, self.cs)
        return self.cl_off(chain[k]) + rem

    def find(self, name):
        for d in self.dirlist():
            if d["name"].lower() == name.lower():
                return d
        return None

    def read_file(self, d):
        buf = b""
        for cl in self.chain(d["cl"]):
            self.f.seek(self.cl_off(cl))
            buf += self.f.read(self.cs)
        return buf[:d["size"]]

    def all_used_clusters(self):
        """Every cluster reachable from the root directory, including files
        inside subdirectories -- without the descent a 'free' cluster could
        still belong to extlinux/extlinux.conf."""
        used = set()
        for d in self.dirlist():
            if d["cl"] < 2:
                continue
            ch = self.chain(d["cl"])
            used.update(ch)
            if d["attr"] & 0x10:
                raw = b""
                for c in ch:
                    self.f.seek(self.cl_off(c))
                    raw += self.f.read(self.cs)
                sub, lfn = [], []
                for i in range(0, len(raw), 32):
                    e = raw[i:i + 32]
                    if e[0] == 0:
                        break
                    if e[11] == 0x0F:
                        continue
                    if e[0] == 0xE5 or (e[11] & 0x10) or e[:2] in (b".\0", b"..\x00"[:2]):
                        continue
                    hi, lo = struct.unpack("<H", e[20:22])[0], struct.unpack("<H", e[26:28])[0]
                    c0 = (hi << 16) | lo
                    if c0 >= 2:
                        used.update(self.chain(c0))
        return used

    def free_clusters(self):
        used = self.all_used_clusters()
        n = (self.fatsz * 512) // 4
        self.f.seek(self.fat0)
        fat = self.f.read(self.fatsz * 512)
        out = []
        for k in range(2, n):
            v = struct.unpack("<I", fat[k * 4:k * 4 + 4])[0] & 0x0FFFFFFF
            if v == 0 and k not in used:
                out.append(k)
        return out


def say(s):
    sys.stdout.buffer.write((s + "\n").encode("ascii", "replace"))


def main():
    mode = sys.argv[1]
    fs = Fat32(writable=(mode == "patch"))
    if mode == "list":
        tot = 0
        for d in fs.dirlist():
            say("  %-28s %12d  cluster=%-7d len=%d%s"
                % (d["name"], d["size"], d["cl"],
                   len(fs.chain(d["cl"])) if d["cl"] >= 2 else 0,
                   "  <DIR>" if d["attr"] & 0x10 else ""))
            tot += d["size"]
        say("files=%d bytes=%d cluster=%d free=%d"
            % (len(fs.dirlist()), tot, fs.cs, len(fs.free_clusters())))
    elif mode == "extract":
        d = fs.find(sys.argv[2])
        if not d:
            sys.exit("目录里找不到 " + sys.argv[2])
        open(sys.argv[3], "wb").write(fs.read_file(d))
        print("提取 %s (%d 字节) -> %s" % (d["name"], d["size"], sys.argv[3]))
    elif mode == "patch":
        name, src = sys.argv[2], sys.argv[3]
        d = fs.find(name)
        if not d:
            sys.exit("目录里找不到 " + name)
        data = open(src, "rb").read()
        need = (len(data) + fs.cs - 1) // fs.cs
        old = fs.chain(d["cl"])
        print("目标 %s: 旧 %d 字节/%d 簇 -> 新 %d 字节/%d 簇"
              % (name, d["size"], len(old), len(data), need))
        if not data:
            sys.exit("源文件为空")
        # 保留原有簇链前段，需要更多簇就从空闲表追加，多出来的簇归还空闲
        cl = old[:need]
        if len(cl) < need:
            used = set(old)
            free = [c for c in fs.free_clusters() if c not in used][:need - len(cl)]
            if len(free) < need - len(cl):
                sys.exit("空闲簇不足")
            for i, c in enumerate(free):
                fs.set_entry(cl[-1], c)
                cl.append(c)
        for i, c in enumerate(cl):
            fs.f.seek(fs.cl_off(c))
            fs.f.write(data[i * fs.cs:(i + 1) * fs.cs].ljust(fs.cs, b"\0"))
        fs.set_entry(cl[-1], 0x0FFFFFF8)
        for c in old[need:]:
            fs.set_entry(c, 0)          # 归还多余簇
        fs.f.seek(d["off"] + 20)        # 首簇高 16 位
        fs.f.write(struct.pack("<H", (cl[0] >> 16) & 0xFFFF))
        fs.f.seek(d["off"] + 26)        # 首簇低 16 位 + 文件长度
        fs.f.write(struct.pack("<H", cl[0] & 0xFFFF))
        fs.f.seek(d["off"] + 28)
        fs.f.write(struct.pack("<I", len(data)))
        fs.f.flush()
        print("已写入, 目录项与 FAT 已更新")
    else:
        sys.exit("未知模式")
    fs.f.close()


if __name__ == "__main__":
    main()
