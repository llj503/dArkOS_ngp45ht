# -*- coding: utf-8 -*-
"""loading.jpg → 天蓝底 + 平滑文字（v3）

v2 的两个问题：logo 白色填充里带 JPEG 噪点（白底发花），因为直接按亮度阈值映射。
v3 改成「先在灰度图上做中值滤波去掉 JPEG 块噪，再用两张干净的 mask 合成」：
  fill mask: lum 58→78 软过渡，>78 全白
  edge mask: lum 15→30 软过渡，<15 全深
文字区域先挖空，最后用 TTF 重画（抗锯齿 + 轻投影）。
"""
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import shutil, os

SRCS = ["/mnt/roms1/launchimages/loading.jpg", "/mnt/roms2/launchimages/loading.jpg"]
BG = (79, 195, 247)
INK = (255, 255, 255)
EDGE = (12, 38, 58)
FONT = "/usr/bin/emulationstation/resources/OpenSans-CondLight.ttf"
OUT_W, OUT_H = 1024, 768

src = None
for p in SRCS:
    if os.path.exists(p + ".bak-ngp"):
        src = p + ".bak-ngp"
        break
assert src, "找不到原始备份"

im = Image.open(src).convert("RGB")
w, h = im.size
lum = im.convert("L")
# 轻微中值滤波：去 JPEG 块噪，又不会糊掉边缘
lum_f = lum.filter(ImageFilter.MedianFilter(3))

def ramp(lo, hi):
    """lum<=lo -> 0, lum>=hi -> 255"""
    def f(v):
        if v <= lo: return 0
        if v >= hi: return 255
        return int((v - lo) * 255.0 / (hi - lo))
    return f

fill_m = lum_f.point(ramp(58, 78))
edge_m = lum_f.point(lambda v: 255 - ramp(15, 30)(v))   # 越暗越白（255=描边）

# 找原文字 bbox（纯白区域），并从两张 mask 里挖掉
px = lum.load()
tx0, ty0, tx1, ty1 = w, h, 0, 0
for y in range(h):
    for x in range(w):
        if px[x, y] > 200:
            tx0 = min(tx0, x); ty0 = min(ty0, y)
            tx1 = max(tx1, x); ty1 = max(ty1, y)

pad = 8
clear = Image.new("L", (w, h), 255)
dc = ImageDraw.Draw(clear)
dc.rectangle([tx0 - pad, ty0 - pad, tx1 + pad, ty1 + pad], fill=0)
from PIL import ImageChops
fill_m = ImageChops.multiply(fill_m, clear)
edge_m = ImageChops.multiply(edge_m, clear)

base = Image.new("RGB", (w, h), BG)
base = Image.composite(Image.new("RGB", (w, h), EDGE), base, edge_m)
base = Image.composite(Image.new("RGB", (w, h), INK), base, fill_m)

# 放大到 1024 宽，垂直居中
scale = OUT_W / float(w)
scaled = base.resize((OUT_W, int(round(h * scale))), Image.LANCZOS)
canvas = Image.new("RGB", (OUT_W, OUT_H), BG)
oy = (OUT_H - scaled.size[1]) // 2
canvas.paste(scaled, (0, oy))

# 重画文字
cx = int(round((tx0 + tx1) / 2.0 * scale))
cy = int(round((ty0 + ty1) / 2.0 * scale)) + oy
target_w = int(round((tx1 - tx0 + 1) * scale))
text = "Please wait..."
size = 10
while size < 200:
    f = ImageFont.truetype(FONT, size)
    bb = f.getbbox(text)
    tw = bb[2] - bb[0]
    if tw >= target_w:
        break
    size += 1
f = ImageFont.truetype(FONT, size)
sh = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
ImageDraw.Draw(sh).text((cx, cy + 2), text, font=f, fill=(10, 40, 60, 110), anchor="mm")
sh = sh.filter(ImageFilter.GaussianBlur(2))
canvas = Image.alpha_composite(canvas.convert("RGBA"), sh).convert("RGB")
ImageDraw.Draw(canvas).text((cx, cy), text, font=f, fill=INK, anchor="mm")

tmp = "/tmp/loading-blue.jpg"
canvas.save(tmp, quality=96, subsampling=0)
canvas.save("/tmp/loading-blue.png")
print("generated %dx%d font=%dpx text_w=%d" % (OUT_W, OUT_H, size, tw))
for p in SRCS:
    if os.path.exists(p + ".bak-ngp"):
        shutil.copyfile(tmp, p)
        print("installed ->", p)
