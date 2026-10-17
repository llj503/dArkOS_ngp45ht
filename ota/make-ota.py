#!/usr/bin/python3
# make-ota.py: build an OTA package from two images of dArkOS for the RG52 Mini.
#
#   sudo ota/make-ota.py OLD.img NEW.img [-o DIR] [--url-base URL] [--feed FEED]
#
# The package updates exactly the build of OLD.img to the build of NEW.img
# (BUILD_ID in /etc/darkos-release of each). It holds the files of the root
# filesystem (p4) and the boot partition (p3) that differ, the sha256 each had
# in OLD and has in NEW, what NEW no longer has, and the boot loader (p1) if
# it changed. Hooks for the release go in ota/hooks/<new version>*.sh.
#
# The device tree on p3 is also what the boot loader of a dual-boot card
# reads for its menu (keys, display); the package is refused if the nodes it
# uses differ between OLD and NEW, unless --allow-dtb-change, after checking
# the menu on a dual-boot card by hand.
#
# docs/OTA.md describes the format and the release procedure.

import argparse
import fnmatch
import gzip
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time

FORMAT = 1
HERE = os.path.dirname(os.path.abspath(__file__))

# Not carried by a package: per-device state, secrets, caches, build leftovers
# and what firstboot consumes. Patterns are fnmatch'ed against the path
# relative to the partition root; a pattern ending in / covers the tree below.
ROOT_EXCLUDE = [
    "boot/", "dev/", "proc/", "sys/", "run/", "tmp/", "mnt/", "media/",
    "roms/", "roms.tar", "tempthemes/", "meson/", "lost+found/",
    ".ota-snapshot-*", "*/.git/", "*/.git",
    "etc/ssh/ssh_host_*", "etc/shadow", "etc/shadow-", "etc/gshadow",
    "etc/gshadow-", "etc/passwd-", "etc/group-", "etc/subuid-", "etc/subgid-",
    "etc/machine-id", "var/lib/dbus/machine-id", "etc/hostname",
    "etc/NetworkManager/system-connections/", "etc/fake-hwclock.data",
    "etc/ld.so.cache",          # made from the libraries: hooks/all-ldconfig.sh
    "var/cache/", "var/log/", "var/tmp/", "var/backups/",
    "var/lib/apt/lists/", "var/lib/dpkg/status-old", "var/lib/dpkg/*-old",
    "var/lib/systemd/", "var/lib/darkos-ota/", "var/lib/bluetooth/",
    "home/ark/pcsx2/", "home/ark/sdl3/", "root/.bash_history",
    "home/ark/.bash_history", "home/ark/.cache/",
]
# Files of the package database that hooks/all-merge-dpkg.sh merges with the
# device's: a package that changes one also carries the old build's version,
# as hooks/base/<path>.gz.
MERGE_BASE = ["var/lib/dpkg/status", "var/lib/apt/extended_states",
              "var/lib/dpkg/triggers/File"]
# On p3: what the dual-boot builder owns (never in a package), and the
# leftovers of firstboot that only a fresh card needs.
BOOT_EXCLUDE = ["dualboot", "bootmenu_*.bmp", "bootmenu2_*.bmp",
                "System Volume Information/"]

# Nodes of the device tree the boot loader's menu uses on a dual-boot card.
DTB_NODES = [r"play_joystick", r"adc-keys", r"saradc@ffaa0000",
             r"dsi@ffb10000", r"panel@0", r"backlight"]


def excluded(rel, patterns):
    for p in patterns:
        if p.endswith("/"):
            q = p[:-1]
            if fnmatch.fnmatch(rel, q) or fnmatch.fnmatch(rel, q + "/*") \
                    or any(fnmatch.fnmatch(rel[:i], q)
                           for i in [m.start() for m in re.finditer("/", rel)]):
                return True
        elif fnmatch.fnmatch(rel, p):
            return True
    return False


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def scan(top, patterns):
    """{rel: (type, st, hashfn)} of everything under top."""
    out = {}
    for dp, dns, fns in os.walk(top):
        rd = os.path.relpath(dp, top)
        rd = "" if rd == "." else rd + "/"
        keep = []
        for d in dns:
            rel = rd + d
            if excluded(rel, patterns) or excluded(rel + "/", patterns):
                continue
            st = os.lstat(os.path.join(dp, d))
            if stat.S_ISLNK(st.st_mode):
                out[rel] = ("link", st)
            else:
                out[rel] = ("dir", st)
                keep.append(d)
        dns[:] = keep
        for f in fns:
            rel = rd + f
            if excluded(rel, patterns):
                continue
            st = os.lstat(os.path.join(dp, f))
            if stat.S_ISLNK(st.st_mode):
                out[rel] = ("link", st)
            elif stat.S_ISREG(st.st_mode):
                out[rel] = ("file", st)
    return out


def ident(top, rel, kind):
    p = os.path.join(top, rel)
    if kind == "link":
        return "link:" + os.readlink(p)
    if kind == "dir":
        return "dir"
    return sha256_file(p)


def diff(old_top, new_top, part, patterns):
    old = scan(old_top, patterns)
    new = scan(new_top, patterns)
    files, dels, size = [], [], 0
    for rel in sorted(new):
        kind, st = new[rel]
        o = old.get(rel)
        meta = dict(mode=stat.S_IMODE(st.st_mode), uid=st.st_uid, gid=st.st_gid)
        if part == "boot":
            meta = dict(mode=0o755, uid=0, gid=0)
        e = dict(part=part, path=rel, type=kind, **meta)
        if kind == "link":
            e["target"] = os.readlink(os.path.join(new_top, rel))
            e["sha256"] = "link:" + e["target"]
        elif kind == "file":
            e["size"] = st.st_size
        if o is None:
            e["old_sha256"] = None
            if kind == "file":
                e["sha256"] = sha256_file(os.path.join(new_top, rel))
                size += st.st_size
            files.append(e)
            continue
        okind, ost = o
        if kind == "dir":
            if okind == "dir" and (part == "boot" or (
                    stat.S_IMODE(ost.st_mode), ost.st_uid, ost.st_gid) ==
                    (meta["mode"], meta["uid"], meta["gid"])):
                continue
            e["old_sha256"] = ident(old_top, rel, okind)
            files.append(e)
            continue
        oh = ident(old_top, rel, okind)
        if kind == "file":
            nh = sha256_file(os.path.join(new_top, rel)) \
                if okind != "file" or ost.st_size == st.st_size else None
            if nh is None:
                nh = sha256_file(os.path.join(new_top, rel))
            e["sha256"] = nh
        e["old_sha256"] = oh
        same_meta = part == "boot" or (stat.S_IMODE(ost.st_mode), ost.st_uid,
                                       ost.st_gid) == (meta["mode"], meta["uid"],
                                                       meta["gid"]) or kind == "link"
        if e["sha256"] == oh:
            if same_meta:
                continue
            e["meta"] = True
        elif kind == "file":
            size += st.st_size
        files.append(e)
    for rel in sorted(old):
        if rel not in new:
            okind, _ = old[rel]
            dels.append(dict(part=part, path=rel, type=okind,
                             old_sha256=ident(old_top, rel, okind)))
    return files, dels, size


def release(root):
    d = {}
    for ln in open(os.path.join(root, "etc/darkos-release")):
        if "=" in ln:
            k, v = ln.strip().split("=", 1)
            d[k] = v.strip('"')
    if "BUILD_ID" not in d:
        sys.exit("%s/etc/darkos-release has no BUILD_ID" % root)
    return d


def dtb_nodes(path):
    dts = subprocess.run(["dtc", "-q", "-I", "dtb", "-O", "dts", path],
                         capture_output=True, text=True, check=True).stdout
    # phandle numbers shift between builds; compare without them
    dts = re.sub(r"<&?0x[0-9a-f]+", "<P", dts)
    dts = re.sub(r"phandle = <[^>]*>;", "", dts)
    out = {}
    lines = dts.splitlines()
    for name in DTB_NODES:
        rx = re.compile(r"^\s*(\S+: )?%s \{" % re.escape(name))
        for i, ln in enumerate(lines):
            if rx.match(ln):
                depth, body = 0, []
                for ln2 in lines[i:]:
                    depth += ln2.count("{") - ln2.count("}")
                    body.append(ln2.strip())
                    if depth == 0:
                        break
                out.setdefault(name, []).append("\n".join(body))
    return out


class Mounted:
    def __init__(self, img):
        self.img = img

    def __enter__(self):
        self.loop = subprocess.run(["losetup", "-r", "--show", "-Pf", self.img],
                                   capture_output=True, text=True,
                                   check=True).stdout.strip()
        subprocess.run(["udevadm", "settle"], capture_output=True)
        self.dirs = {}
        for n, part in ((1, None), (3, "boot"), (4, "root")):
            if part:
                d = tempfile.mkdtemp(prefix="ota-%s-" % part)
                subprocess.run(["mount", "-o", "ro", "%sp%d" % (self.loop, n), d],
                               check=True)
                self.dirs[part] = d
        return self

    def uboot(self):
        with open("%sp1" % self.loop, "rb") as f:
            return f.read()

    def __exit__(self, *a):
        for d in self.dirs.values():
            subprocess.run(["umount", d])
            os.rmdir(d)
        subprocess.run(["losetup", "-d", self.loop])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("old")
    ap.add_argument("new")
    ap.add_argument("-o", "--outdir", default=".")
    ap.add_argument("--url-base", help="where the package will be downloaded "
                    "from (the release's download URL), for the feed entry")
    ap.add_argument("--feed", help="feed JSON to add the entry to")
    ap.add_argument("--allow-dtb-change", action="store_true")
    ap.add_argument("--min-battery", type=int, default=20)
    ap.add_argument("--hooks-dir", default=os.path.join(HERE, "hooks"),
                    help="where the release hooks are (default ota/hooks)")
    a = ap.parse_args()
    if os.geteuid() != 0:
        sys.exit("run as root (it mounts the images)")

    with Mounted(a.old) as O, Mounted(a.new) as N:
        ro, rn = release(O.dirs["root"]), release(N.dirs["root"])
        if ro["BUILD_ID"] == rn["BUILD_ID"]:
            sys.exit("both images are build %s" % ro["BUILD_ID"])
        print("%s (%s) -> %s (%s)" % (ro.get("VERSION"), ro["BUILD_ID"],
                                      rn.get("VERSION"), rn["BUILD_ID"]))

        do, dn = (os.path.join(X.dirs["boot"], "rk3562-rg52mini.dtb") for X in (O, N))
        if os.path.exists(do) and os.path.exists(dn) and sha256_file(do) != sha256_file(dn):
            no, nn = dtb_nodes(do), dtb_nodes(dn)
            bad = [k for k in DTB_NODES if no.get(k) != nn.get(k)]
            if bad:
                msg = ("the device tree changed in nodes the dual-boot menu uses: "
                       + ", ".join(bad))
                if not a.allow_dtb_change:
                    sys.exit(msg + "\ncheck the menu on a dual-boot card with the "
                             "new image, then rerun with --allow-dtb-change")
                print("WARNING: " + msg)

        print("comparing the root filesystem...")
        rf, rd, rs = diff(O.dirs["root"], N.dirs["root"], "root", ROOT_EXCLUDE)
        print("comparing the boot partition...")
        bf, bd, bs = diff(O.dirs["boot"], N.dirs["boot"], "boot", BOOT_EXCLUDE)
        uo, un = O.uboot(), N.uboot()

        name = "dArkOS_rg52mini_ota_%s_%s-to-%s_%s" % (
            ro.get("VERSION"), ro["BUILD_ID"], rn.get("VERSION"), rn["BUILD_ID"])
        work = tempfile.mkdtemp(prefix="ota-pkg-", dir=a.outdir)
        try:
            pay = os.path.join(work, "payload")
            for part, files, top in (("root", rf, N.dirs["root"]),
                                     ("boot", bf, N.dirs["boot"])):
                lst = [e["path"] for e in files if e["type"] == "file"
                       and not e.get("meta")]
                if not lst:
                    continue
                os.makedirs(os.path.join(pay, part))
                listf = os.path.join(work, part + ".list")
                open(listf, "wb").write(b"\0".join(p.encode() for p in lst) + b"\0")
                subprocess.run(["rsync", "-a", "--numeric-ids", "--from0",
                                "--files-from=" + listf, top + "/",
                                os.path.join(pay, part) + "/"], check=True)
            members = ["manifest.json"]
            manifest = dict(format=FORMAT, device="rg52mini",
                            version=rn.get("VERSION"), build_id=rn["BUILD_ID"],
                            from_version=ro.get("VERSION"),
                            from_build_id=ro["BUILD_ID"],
                            datetime=int(time.time()), min_battery=a.min_battery,
                            root_bytes=rs, boot_bytes=bs,
                            files=rf + bf, delete=rd + bd, hooks=[])
            if os.path.isdir(pay):
                pz = os.path.join(work, "payload.tar.zst")
                subprocess.run(["tar", "--zstd", "-c", "--numeric-owner", "-f", pz,
                                "-C", pay, "."], check=True,
                               env=dict(os.environ, ZSTD_CLEVEL="19", ZSTD_NBTHREADS="0"))
                manifest["payload_sha256"] = sha256_file(pz)
                members.append("payload.tar.zst")
            if uo != un:
                open(os.path.join(work, "uboot.img"), "wb").write(un)
                manifest["uboot"] = dict(size=len(un),
                                         sha256=hashlib.sha256(un).hexdigest(),
                                         old_sha256=hashlib.sha256(uo[:len(un)]).hexdigest())
                members.append("uboot.img")
            hooks_dir = a.hooks_dir
            v = rn.get("VERSION", "")
            if os.path.isdir(hooks_dir):
                for h in sorted(os.listdir(hooks_dir)):
                    # the release's own, then all-*.sh for every package
                    if h.endswith(".sh") and (h == v + ".sh" or h.startswith(v + "-")
                                              or h.startswith("all-")):
                        os.makedirs(os.path.join(work, "hooks"), exist_ok=True)
                        shutil.copy(os.path.join(hooks_dir, h), os.path.join(work, "hooks", h))
                        manifest["hooks"].append("hooks/" + h)
                        members.append("hooks/" + h)
            for e in rf:
                if e["path"] in MERGE_BASE and e["type"] == "file" and not e.get("meta") \
                        and os.path.isfile(os.path.join(O.dirs["root"], e["path"])):
                    b = os.path.join("hooks", "base", e["path"] + ".gz")
                    os.makedirs(os.path.dirname(os.path.join(work, b)), exist_ok=True)
                    with open(os.path.join(O.dirs["root"], e["path"]), "rb") as f, \
                            gzip.open(os.path.join(work, b), "wb") as g:
                        shutil.copyfileobj(f, g)
                    members.append(b)
            json.dump(manifest, open(os.path.join(work, "manifest.json"), "w"), indent=1)
            pkg = os.path.join(a.outdir, name + ".tar")
            with tarfile.open(pkg, "w:", format=tarfile.GNU_FORMAT) as t:
                for m in members:
                    t.add(os.path.join(work, m), m)
        finally:
            shutil.rmtree(work)

    sha = sha256_file(pkg)
    size = os.path.getsize(pkg)
    nf = sum(1 for e in rf + bf if e["type"] == "file")
    print("package %s: %d MiB, %d files (%d MiB unpacked), %d to delete%s"
          % (pkg, size >> 20, nf, (rs + bs) >> 20, len(rd + bd),
             ", boot loader" if uo != un else ""))
    print("sha256 " + sha)
    entry = dict(device="rg52mini", version=rn.get("VERSION"), build_id=rn["BUILD_ID"],
                 from_version=ro.get("VERSION"), from_build_id=ro["BUILD_ID"],
                 datetime=manifest["datetime"], filename=os.path.basename(pkg),
                 size=size, sha256=sha,
                 url=(a.url_base.rstrip("/") + "/" + os.path.basename(pkg))
                 if a.url_base else os.path.basename(pkg))
    print(json.dumps(entry, indent=1))
    if a.feed:
        try:
            feed = json.load(open(a.feed))
        except (OSError, ValueError):
            feed = {"response": []}
        feed["response"] = [e for e in feed["response"]
                            if e.get("from_build_id") != entry["from_build_id"]
                            or e.get("build_id") != entry["build_id"]] + [entry]
        json.dump(feed, open(a.feed, "w"), indent=1)
        open(a.feed, "a").write("\n")
        print("feed: " + a.feed)


if __name__ == "__main__":
    main()
