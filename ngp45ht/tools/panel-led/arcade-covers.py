#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""arcade-covers.py — 给街机系统抓 libretro 的封面（Named_Boxarts）

为什么需要单独脚本：街机 ROM 是 1941.zip 这种短名，而 libretro 缩略图按
**游戏全名**命名（`1941 - Counter Attack (World).png`），所以要用 ES 的
mamenames.xml（短名→官方全名）去匹配 CDN 的目录清单。

数据源：https://thumbnails.libretro.com/FBNeo%20-%20Arcade%20Games/Named_Boxarts/
（Apache 目录清单，约 6400 张；索引 1.6 MB，一次拉下来本地匹配）

输出：<系统目录>/images/<rom>-image.png，并可选把 <image> 写进 gamelist.xml

用法：
    arcade-covers.py /roms2/cps1 [--limit N] [--dry]
"""
import os
import re
import subprocess
import sys
import urllib.parse
import difflib

BASE = "https://thumbnails.libretro.com/FBNeo%20-%20Arcade%20Games/Named_Boxarts"
MAMENAMES = "/usr/bin/emulationstation/resources/mamenames.xml"


def fetch_index():
    if os.path.exists("/tmp/idx.html") and os.path.getsize("/tmp/idx.html") > 100000:
        html = open("/tmp/idx.html", encoding="utf-8", errors="replace").read()
    else:
        html = subprocess.run(["curl", "-sL", "--max-time", "60", BASE + "/"],
                              capture_output=True, text=True).stdout
        open("/tmp/idx.html", "w", encoding="utf-8").write(html)
    names = re.findall(r">([^<]+\.png)<", html)
    names = [urllib.parse.unquote(n) for n in names]
    return names


def load_mamenames():
    s = open(MAMENAMES, encoding="utf-8", errors="replace").read()
    out = {}
    for m in re.finditer(r"<game>\s*<mamename>(.*?)</mamename>\s*<realname>(.*?)</realname>", s, re.S):
        out[m.group(1)] = m.group(2)
    return out


def norm(s):
    s = s.lower()
    s = s.replace("’", "'").replace(":", " - ").replace("–", "-")
    s = re.sub(r"\s+", " ", s).strip()
    return s


def primary(s):
    """取第一个括号之前的部分做粗匹配"""
    return norm(re.split(r"\(|\[", s)[0]).strip(" -")


def region_hint(s):
    m = re.search(r"\((world|usa|japan|euro|asia|korea|china|taiwan)[^)]*\)", s, re.I)
    return m.group(1).lower() if m else ""


# 改版/自制版在 MAME 名库里没有条目，直接借原版封面
ALIAS = {
    "knightsh": "Knights of the Round (World 911127)",
    "kodh":     "The King of Dragons (World 910805)",
    "dinoh":    "Cadillacs and Dinosaurs (World 930201)",
    "wofch":    "Warriors of Fate (World 921031)",
    "wofhfh":   "Warriors of Fate (World 921031)",
    "sgyxz":    "Warriors of Fate (World 921031)",
    "sf2tlona": "Street Fighter II': Champion Edition (World 920513)",
    "sf2dongb": "Street Fighter II': Champion Edition (World 920513)",
    "sf2koryu": "Street Fighter II': Champion Edition (World 920513)",
    "sf2rb":    "Street Fighter II': Champion Edition (World 920513)",
    "sf2red":   "Street Fighter II': Champion Edition (World 920513)",
    "sf2mdt":   "Street Fighter II': Champion Edition (World 920513)",
    "sfzch":    "Street Fighter Alpha: Warriors' Dreams (Euro 950727)",
    "cps1frog": "Nemo (World 901130)",
    "ffightjh": "Final Fight (World, set 1)",
}


def closest(key, keys):
    """精确匹配失败时用 difflib 兜底"""
    m = difflib.get_close_matches(key, keys, n=1, cutoff=0.86)
    return m[0] if m else None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry" in sys.argv
    limit = None
    for i, a in enumerate(sys.argv):
        if a == "--limit":
            limit = int(sys.argv[i + 1])
    if not args:
        print(__doc__)
        return 1
    d = args[0].rstrip("/")
    roms = sorted(f for f in os.listdir(d) if f.lower().endswith(".zip"))
    if limit:
        roms = roms[:limit]
    mm = load_mamenames()
    idx = fetch_index()
    print("CDN 清单 %d 张，本地 %d 个 ROM" % (len(idx), len(roms)))

    by_primary = {}
    for n in idx:
        by_primary.setdefault(primary(n), []).append(n)

    imgdir = os.path.join(d, "images")
    if not dry:
        os.makedirs(imgdir, exist_ok=True)

    ok = miss = 0
    misses = []
    for f in roms:
        rom = f[:-4]
        dst = os.path.join(imgdir, rom + "-image.png")
        if not dry and os.path.exists(dst) and os.path.getsize(dst) > 2000:
            ok += 1
            continue
        real = mm.get(rom) or ALIAS.get(rom)
        if not real:
            miss += 1
            misses.append(rom + " (名库无)")
            continue
        key = primary(real)
        cands = by_primary.get(key, [])
        if not cands:
            c = closest(key, list(by_primary.keys()))
            if c:
                cands = by_primary[c]
        if not cands:
            miss += 1
            misses.append(rom + " -> " + real)
            continue
        hint = region_hint(real)
        pick = None
        for c in cands:
            if hint and region_hint(c) == hint:
                pick = c
                break
        pick = pick or cands[0]
        url = BASE + "/" + urllib.parse.quote(pick)
        dst = os.path.join(imgdir, rom + "-image.png")
        if dry:
            print("  %-14s -> %s" % (rom, pick))
            ok += 1
            continue
        r = subprocess.run(["curl", "-sL", "--max-time", "40", "-o", dst, url])
        if r.returncode == 0 and os.path.exists(dst) and os.path.getsize(dst) > 2000:
            ok += 1
        else:
            if os.path.exists(dst):
                os.remove(dst)
            miss += 1
            misses.append(rom + " (下载失败)")

    print("成功 %d，失败 %d" % (ok, miss))
    for m in misses[:10]:
        print("  缺:", m)
    return 0


if __name__ == "__main__":
    sys.exit(main())
