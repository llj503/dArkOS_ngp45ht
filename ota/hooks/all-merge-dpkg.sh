#!/bin/bash
# In every package, last: merge the package database. The client keeps
# /var/lib/dpkg/status as a file the user changed when it differs from the old
# build's (anything installed or removed with apt), and puts the new one beside
# it - so dpkg would not know the packages the update added. Taking the new
# one instead would make it forget the user's.
#
# The package carries the old build's version of each file below as
# hooks/base/<path>.gz (make-ota.py, MERGE_BASE); the new one is in the stage
# the client unpacked the payload to, next to hooks/. Per package (Package and
# Architecture): if the update changed its entry, the new build's entry wins,
# else the device's stays. Files of dpkg/info/ in the same conflict (a package
# both the user and the update changed) take the new build's, as its entry did.
#
# What is merged is added to /var/lib/darkos-ota/merged, from where the client
# (1.1 on) puts it back on a rollback. The client empties the list before an
# update; hooks that run earlier add to it too. A failure here leaves the
# .ota-new files as they are and never fails the update.
python3 - "$(readlink -f "$0")" <<'EOF'
import gzip, hashlib, os, sys, time

STAGE = os.path.dirname(os.path.dirname(sys.argv[1]))
BASE = os.path.join(STAGE, "hooks", "base")
MERGED = "/var/lib/darkos-ota/merged"
FILES = [("var/lib/dpkg/status", "stanzas"),
         ("var/lib/apt/extended_states", "stanzas"),
         ("var/lib/dpkg/triggers/File", "lines")]


def log(msg):
    print(msg, flush=True)
    try:
        with open("/var/lib/darkos-ota/ota.log", "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


def read(p):
    with (gzip.open if p.endswith(".gz") else open)(p, "rb") as f:
        return f.read().decode()


def sha(p):
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def stanzas(text):
    out = {}
    for s in text.split("\n\n"):
        s = s.strip("\n")
        if not s:
            continue
        f = dict(ln.split(":", 1) for ln in s.split("\n")
                 if ln[:1] not in (" ", "\t") and ":" in ln)
        out[(f["Package"].strip(), f.get("Architecture", "").strip())] = s
    return out


def merge_stanzas(b, d, n):
    B, D, N = stanzas(b), stanzas(d), stanzas(n)
    # the device's order, what the update adds at the end (sorted, if the
    # device's was: dpkg writes status sorted)
    keys = list(D) + [k for k in N if k not in D]
    if list(D) == sorted(D):
        keys.sort()
    out, upd, own = [], 0, 0
    for k in keys:
        if N.get(k) != B.get(k):
            v = N.get(k)
            upd += D.get(k) != v
        else:
            v = D.get(k)
            own += v != B.get(k)
        if v is not None:
            out.append(v)
    return "".join(s + "\n\n" for s in out), upd, own


def merge_lines(b, d, n):
    B, D, N = (set(x.splitlines()) for x in (b, d, n))
    keep = [ln for ln in d.splitlines() if ln in N or ln not in B]
    add = [ln for ln in n.splitlines() if ln not in B and ln not in D]
    upd = len(add) + sum(1 for ln in D if ln in B and ln not in N)
    own = sum(1 for ln in D if ln not in B and ln not in N)
    return "".join(ln + "\n" for ln in keep + add), upd, own


def replace(dst, data=None, src=None):
    with open(MERGED, "a") as f:
        f.write(dst + "\n")
    if src:
        os.replace(src, dst)
        return
    st = os.stat(dst)
    tmp = os.path.join(os.path.dirname(dst), ".ota-tmp." + os.path.basename(dst))
    with open(tmp, "w") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.chown(tmp, st.st_uid, st.st_gid)
    os.chmod(tmp, st.st_mode & 0o7777)
    os.replace(tmp, dst)


os.makedirs(os.path.dirname(MERGED), exist_ok=True)
for rel, kind in FILES:
    base, new, dev = os.path.join(BASE, rel + ".gz"), os.path.join(STAGE, "root", rel), "/" + rel
    try:
        if not (os.path.isfile(base) and os.path.isfile(new) and os.path.isfile(dev)):
            continue
        b, d, n = read(base), read(dev), read(new)
        if d in (n, b):
            continue            # the client replaced it, or it is already new
        out, upd, own = (merge_stanzas if kind == "stanzas" else merge_lines)(b, d, n)
        replace(dev, out)
        if os.path.isfile(dev + ".ota-new") and read(dev + ".ota-new") == n:
            os.unlink(dev + ".ota-new")
        log("  merged: %s (%d entries from the update, %d of this device kept)"
            % (dev, upd, own))
    except Exception as ex:
        log("  merge %s failed, left as kept: %s" % (dev, ex))

info = os.path.join(STAGE, "root", "var/lib/dpkg/info")
for name in sorted(os.listdir(info)) if os.path.isdir(info) else []:
    dev = "/var/lib/dpkg/info/" + name
    try:
        h = sha(os.path.join(info, name))
        if os.path.isfile(dev + ".ota-new") and sha(dev + ".ota-new") == h \
                and os.path.isfile(dev) and sha(dev) != h:
            replace(dev, src=dev + ".ota-new")
            log("  merged: %s (the update's)" % dev)
    except Exception as ex:
        log("  merge %s failed, left as kept: %s" % (dev, ex))
EOF
exit 0
