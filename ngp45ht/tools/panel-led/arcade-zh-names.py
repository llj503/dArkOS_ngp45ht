# -*- coding: utf-8 -*-
"""给 cps1（以及任何街机系统）写中文游戏名到 gamelist.xml。

为什么需要：街机系统里 ES 不用文件名，而是查内建的
`/usr/bin/emulationstation/resources/mamenames.xml`（MAME 官方英文名库，30444 条），
所以 1941.zip 会显示成 "1941: Counter Attack (World 900227)"。
只有 gamelist.xml 里的 `<name>` 能覆盖它。GBA 等家用机本来就用中文文件名，不用管。

用法：arcade-zh-names.py <系统目录>      例如 /roms2/cps1
脚本幂等，保留已有的 playcount / lastplayed / image 等字段。
"""
import os
import re
import sys
from xml.sax.saxutils import escape

# ROM 名 -> 中文名
ZH = {
    "1941":       "1941 反击战",
    "3wonders":   "三个奇迹",
    "captcomm":   "名将",
    "cawing":     "雌虎战机",
    "cps1frog":   "青蛙（改版）",
    "dino":       "恐龙快打",
    "dinoh":      "恐龙快打（改版）",
    "dinohunt":   "恐龙猎人（中文改版）",
    "dynwar":     "吞食天地",
    "dynwarjr":   "吞食天地（日版）",
    "ffight":     "快打旋风",
    "ffightjh":   "快打旋风（日版改版）",
    "forgottn":   "失落的世界",
    "ganbare":    "加油！海君（日版）",
    "ghouls":     "大魔界村",
    "knights":    "圆桌骑士",
    "knightsh":   "圆桌骑士（改版）",
    "kod":        "龙王战士",
    "kodh":       "龙王战士（改版）",
    "mbombrd":    "摔跤霸王 双人组",
    "megaman":    "洛克人 力量之战",
    "mercs":      "战场之狼2",
    "msword":     "魔法剑",
    "mtwins":     "双子星",
    "nemo":       "小尼莫",
    "pang3":      "泡泡龙3",
    "pnickj":     "噗尼奇（日版）",
    "punisher":   "惩罚者",
    "punisherbz": "惩罚者（飙风战警 中文版）",
    "sf2":        "街头霸王2",
    "sf2ce":      "街头霸王2 冠军版",
    "sf2dongb":   "街霸2 冠军版（东方不败）",
    "sf2hf":      "街霸2 极速版",
    "sf2koryu":   "街霸2 冠军版（降龙）",
    "sf2mdt":     "街霸2 魔法加强版",
    "sf2rb":      "街霸2 彩虹版",
    "sf2red":     "街霸2 红波版",
    "sf2tlona":   "街霸2（屠龙版）",
    "sfzch":      "少年街霸（中文改版）",
    "sgyxz":      "三国志（改版）",
    "slammast":   "周末夜摔跤",
    "strider":    "出击飞龙",
    "unsquad":    "联合国空军",
    "varth":      "雷暴行动",
    "willow":     "风云际会",
    "wof":        "吞食天地2",
    "wofch":      "吞食天地2（中文版）",
    "wofhfh":     "火凤凰 三国志2（中文版）",
}


def existing(path):
    """读已有 gamelist，返回 {path: 其它字段的原始 XML 片段}"""
    out = {}
    if not os.path.exists(path):
        return out
    s = open(path, encoding="utf-8", errors="replace").read()
    for m in re.finditer(r"<game>(.*?)</game>", s, re.S):
        blk = m.group(1)
        pm = re.search(r"<path>(.*?)</path>", blk, re.S)
        if not pm:
            continue
        key = pm.group(1).strip()
        keep = []
        for tm in re.finditer(r"<(playcount|lastplayed|favorite|hidden)>(.*?)</\1>", blk, re.S):
            keep.append("\t\t<%s>%s</%s>" % (tm.group(1), tm.group(2), tm.group(1)))
        out[key] = keep
    return out


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    d = sys.argv[1].rstrip("/")
    gl = os.path.join(d, "gamelist.xml")
    old = existing(gl)

    roms = sorted(f for f in os.listdir(d) if f.lower().endswith(".zip"))
    lines = ['<?xml version="1.0"?>', "<gameList>"]
    named = unknown = 0
    for f in roms:
        rom = f[:-4]
        zh = ZH.get(rom)
        if zh:
            named += 1
        else:
            unknown += 1
            zh = rom            # 没有中文名就退回 ROM 名
        lines.append("\t<game>")
        lines.append("\t\t<path>./%s</path>" % escape(f))
        lines.append("\t\t<name>%s</name>" % escape(zh))
        # 封面：/images/<rom>-image.png（由 arcade-covers.py 抓 libretro 缩略图）
        if os.path.exists(os.path.join(d, "images", rom + "-image.png")):
            lines.append("\t\t<image>./images/%s-image.png</image>" % escape(rom))
        for extra in old.get("./" + f, []):
            lines.append(extra)
        lines.append("\t</game>")
    lines.append("</gameList>")

    if os.path.exists(gl) and not os.path.exists(gl + ".bak-ngp"):
        open(gl + ".bak-ngp", "w", encoding="utf-8").write(
            open(gl, encoding="utf-8", errors="replace").read())
    open(gl, "w", encoding="utf-8", newline="\n").write("\n".join(lines) + "\n")
    print("%s: %d 个游戏，%d 个有中文名，%d 个没收录" % (gl, len(roms), named, unknown))
    return 0


if __name__ == "__main__":
    sys.exit(main())
