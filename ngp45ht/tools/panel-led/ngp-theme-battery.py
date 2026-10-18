#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ngp-theme-battery.py — 给 EmulationStation 主题补上电池 + WiFi 状态元素

背景
----
ES 的右上角电池/wifi 不是内建画出来的，而是**主题元素**：
`<batteryIndicator name="batteryIndicator">`，WiFi 走其中的 `<networkIcon>`。
资源可以用 ES 内建的 `:/battery/*.svg` 与 `:/network.svg`（不是 `:/resources/…`）。

实测（2026-10-18）：
  * `es-theme-minimal-arkos` 完全没有这个元素 → 右上角空
  * `es-theme-albedo` 把它放在 `settings/display/view-general.xml`，受 `ifSubset`
    （StatusBar:statusBattery）控制，实际不生效 → 右上角同样空
  * `es-theme-nes-box` 也没有

所以统一做法：往每个主题自己的 `theme.xml` 里塞一份自包含的 batteryIndicator，
资源一律用 ES 内建的 svg，不依赖主题素材。

用法
----
    ngp-theme-battery.py <主题目录> [<主题目录> ...]
    ngp-theme-battery.py --all        # 扫 $HOME/.emulationstation/themes 与 /roms/themes

幂等：theme.xml 里已经出现 batteryIndicator 就跳过。
"""
import os
import sys

BLOCK = """
    <!-- NGP45HT 补：ES 的电池/wifi 图标由主题元素 batteryIndicator 画
         （wifi 走 networkIcon），资源用 ES 内建的 /battery/*.svg 与 /network.svg。
         不给 fontPath/fontSize 时「图标和文字」模式只出图标，所以显式给一份。 -->
    <batteryIndicator name="batteryIndicator">
      <pos>0.880 0.022</pos>
      <size>0.042</size>
      <itemSpacing>0.006</itemSpacing>
      <color>FFFFFF</color>
      <fontPath>./assets/noto.ttf</fontPath>
      <fontSize>0.030</fontSize>
      <textColor>FFFFFF</textColor>
      <full>:/battery/full.svg</full>
      <at75>:/battery/75.svg</at75>
      <at50>:/battery/50.svg</at50>
      <at25>:/battery/25.svg</at25>
      <empty>:/battery/empty.svg</empty>
      <incharge>:/battery/incharge.svg</incharge>
      <networkIcon>:/network.svg</networkIcon>
    </batteryIndicator>
"""

FONT_CANDIDATES = ["./assets/noto.ttf", "./assets/miss.ttf"]


def pick_font(tdir):
    for f in FONT_CANDIDATES:
        if os.path.exists(os.path.join(tdir, f[2:])):
            return f
    return None


def patch(tdir):
    path = os.path.join(tdir, "theme.xml")
    if not os.path.isfile(path):
        return "skip (no theme.xml)"
    raw = open(path, "rb").read()
    bom = raw.startswith(b"\xef\xbb\xbf")
    txt = raw.decode("utf-8-sig", errors="replace")

    if "batteryIndicator" in txt:
        return "skip (already has batteryIndicator)"

    font = pick_font(tdir)
    blk = BLOCK
    if font is None:
        blk = "\n".join(l for l in BLOCK.splitlines() if "<fontPath>" not in l) + "\n"

    if '<view name="screen">' in txt:
        i = txt.index('<view name="screen">') + len('<view name="screen">')
        txt = txt[:i] + blk + txt[i:]
        how = "inserted into existing screen view"
    elif "</theme>" in txt:
        j = txt.rindex("</theme>")
        txt = txt[:j] + '<view name="screen">' + blk + '</view>\n\n' + txt[j:]
        how = "appended new screen view"
    else:
        return "skip (no </theme>)"

    out = txt.encode("utf-8")
    if bom:
        out = b"\xef\xbb\xbf" + out
    open(path, "wb").write(out)
    return how + ((" (font %s)" % font) if font else " (no theme font)")


def all_themes():
    home = os.path.expanduser("~")
    roots = [os.path.join(home, ".emulationstation", "themes"),
             "/roms/themes", "/roms2/themes"]
    seen, out = set(), []
    for r in roots:
        if not os.path.isdir(r):
            continue
        for d in sorted(os.listdir(r)):
            p = os.path.join(r, d)
            if os.path.isdir(p) and p not in seen:
                seen.add(p)
                out.append(p)
    return out


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    targets = all_themes() if args == ["--all"] else args
    for t in targets:
        print("%-52s %s" % (t, patch(t)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
