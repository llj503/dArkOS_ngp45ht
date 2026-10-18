#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""pegasus2es.py — 把「天马G / Pegasus」的游戏包转换给 dArkOS 的 EmulationStation 用

天马G 的目录长这样：
    <系统>/
        xxx.zip
        metadata.pegasus.txt
        media/<游戏名>/boxfront.png  logo.png  video.mp4  mini_boxfront.png ...
Pegasus 靠 metadata.pegasus.txt + 同名 media 目录显示名字/封面/视频；
EmulationStation 只认 gamelist.xml 和 images/ 目录，所以需要转换。

本脚本做的事：
  * 解析 metadata.pegasus.txt（game:/file:/developer:/genre:/players:/release:/description:）
  * 为每个游戏在 media/ 下找封面（boxfront.png / boxFront.png / boxfront.jpg / boxFront.jpg，
    大小写都可能不一样，做大小写不敏感匹配）
  * 生成 gamelist.xml：<name> <desc> <image> <marquee> <video> <developer> <genre>
    <players> <releasedate> <sortname>
  * **图片/视频直接引用 media 下的文件，不复制**（省空间）
  * 保留已有的 playcount / lastplayed / favorite / hidden

用法：
    pegasus2es.py <系统目录>              # 原地生成 gamelist.xml
    pegasus2es.py <系统目录> --only-name  # 只写名字（不引用媒体）
"""
import os
import re
import sys
from xml.sax.saxutils import escape

COVER_NAMES = ["boxfront.png", "boxFront.png", "boxfront.jpg", "boxFront.jpg",
               "BoxFront.png", "Boxart.png", "boxart.png"]
LOGO_NAMES = ["logo.png", "Logo.png", "logo.jpg"]
VIDEO_NAMES = ["video.mp4", "Video.mp4", "video.webm"]


def parse_metadata(path):
    """返回 [{k: v}]，每个 dict 是一次 game 块"""
    games = []
    cur = None
    key = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            line = raw.rstrip("\n")
            if not line.strip():
                key = None
                continue
            m = re.match(r"^([A-Za-z][A-Za-z0-9_.\-]*)\s*:\s?(.*)$", line)
            if m:
                key = m.group(1).lower()
                val = m.group(2)
                if key == "game":
                    cur = {"game": val}
                    games.append(cur)
                elif cur is not None:
                    cur[key] = val
            elif key and cur is not None:
                cur[key] = (cur.get(key, "") + "\n" + line).strip()
    return games


def find_in(dirpath, names):
    if not os.path.isdir(dirpath):
        return None
    lower = {}
    for f in os.listdir(dirpath):
        lower.setdefault(f.lower(), f)
    for n in names:
        real = lower.get(n.lower())
        if real:
            return real
    return None


def split_desc(s):
    """Pegasus 的 description 里用字面 \\n 表示换行"""
    return s.replace("\\n", "\n")


def date_to_es(s):
    """2021-03-21 -> 20210321T000000"""
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})", s.strip())
    return "%s%s%sT000000" % m.groups() if m else ""


def existing_extra(gl):
    out = {}
    if not os.path.exists(gl):
        return out
    s = open(gl, encoding="utf-8", errors="replace").read()
    for m in re.finditer(r"<game>(.*?)</game>", s, re.S):
        blk = m.group(1)
        pm = re.search(r"<path>(.*?)</path>", blk, re.S)
        if not pm:
            continue
        keep = []
        for tm in re.finditer(r"<(playcount|lastplayed|favorite|hidden)>(.*?)</\1>", blk, re.S):
            keep.append((tm.group(1), tm.group(2)))
        out[pm.group(1).strip()] = keep
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    only_name = "--only-name" in sys.argv
    if not args:
        print(__doc__)
        return 1
    d = args[0].rstrip("/")
    meta = os.path.join(d, "metadata.pegasus.txt")
    if not os.path.exists(meta):
        print("找不到 %s" % meta)
        return 1

    games = parse_metadata(meta)
    gl = os.path.join(d, "gamelist.xml")
    extra = existing_extra(gl)

    out = ['<?xml version="1.0"?>', "<gameList>"]
    have_cover = have_logo = have_video = 0
    written = set()

    for g in games:
        fname = g.get("file") or g.get("game")
        if not fname:
            continue
        rom = fname.strip()
        if not os.path.exists(os.path.join(d, rom)):
            # 扩展名/大小写对不上就跳过（避免生成死条目）
            continue
        title = g.get("game", os.path.splitext(rom)[0])
        mdir = os.path.join(d, "media", title)

        out.append("\t<game>")
        out.append("\t\t<path>./%s</path>" % escape(rom))
        out.append("\t\t<name>%s</name>" % escape(title))
        if g.get("sort-by"):
            out.append("\t\t<sortname>%s</sortname>" % escape(g["sort-by"]))
        if g.get("developer"):
            out.append("\t\t<developer>%s</developer>" % escape(g["developer"]))
        if g.get("publisher"):
            out.append("\t\t<publisher>%s</publisher>" % escape(g["publisher"]))
        if g.get("genre"):
            out.append("\t\t<genre>%s</genre>" % escape(g["genre"]))
        if g.get("players"):
            out.append("\t\t<players>%s</players>" % escape(g["players"]))
        if g.get("release"):
            out.append("\t\t<releasedate>%s</releasedate>" % date_to_es(g["release"]))
        if g.get("description"):
            out.append("\t\t<desc>%s</desc>" % escape(split_desc(g["description"])))

        if not only_name:
            a = g.get("assets.boxfront") or g.get("assets.boxFront")
            cover = os.path.basename(a) if a else None
            if not cover or not os.path.exists(os.path.join(mdir, cover)):
                cover = find_in(mdir, COVER_NAMES)
            if cover:
                out.append("\t\t<image>./media/%s/%s</image>" % (escape(title), escape(cover)))
                have_cover += 1
            logo = find_in(mdir, LOGO_NAMES)
            if logo:
                out.append("\t\t<marquee>./media/%s/%s</marquee>" % (escape(title), escape(logo)))
                have_logo += 1
            video = find_in(mdir, VIDEO_NAMES)
            if video:
                out.append("\t\t<video>./media/%s/%s</video>" % (escape(title), escape(video)))
                have_video += 1

        for k, v in extra.get("./" + rom, []):
            out.append("\t\t<%s>%s</%s>" % (k, v, k))
        out.append("\t</game>")
        written.add("./" + rom)

    out.append("</gameList>")

    if os.path.exists(gl) and not os.path.exists(gl + ".bak-ngp"):
        open(gl + ".bak-ngp", "w", encoding="utf-8").write(
            open(gl, encoding="utf-8", errors="replace").read())
    open(gl, "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
    print("%s: 元数据 %d 条，写入 %d 条；封面 %d，logo %d，视频 %d"
          % (gl, len(games), len(written), have_cover, have_logo, have_video))
    return 0


if __name__ == "__main__":
    sys.exit(main())
