#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build a <=512-glyph PSF1 console font from the GNU Unifont BDF.

Why not bdf2psf: it derives the glyph width from AVERAGE_WIDTH and silently
skips any bitmap row wider than that -- Unifont's BDF mixes 8-wide ASCII with
16-wide CJK, so every Hanzi was dropped ("U+4E2D: no glyph defined").

This converter:
  1. parses the BDF, normalising every glyph to a 16x16 cell (left-aligned),
  2. assigns glyph positions: ASCII 0x20-0x7E at their natural positions,
     everything else from position 256 upward in codepoint order,
  3. writes a PSF1 font (mode 0x03 = 512 glyphs + unicode table) whose
     unicode table maps each codepoint to its position.

Symbol selection: read from panel.sym (U+XXXX per line) if present, else
default to ASCII + box drawing + arrows + common punctuation.
"""
import sys

BDF = "unifont.bdf"
SYM = "panel.sym"
OUT = "Unifont-CJK-panel.psf"

W = H = 16          # target cell
ROWBYTES = W // 8   # 2
GLYPH_SIZE = ROWBYTES * H  # 32
FONT_POSITIONS = 512

def parse_bdf(path):
    glyphs = {}   # codepoint -> bytes(32)
    cur = None
    in_bitmap = False
    bbx = None
    rows = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line.startswith("STARTCHAR"):
                cur, in_bitmap, rows, bbx = line[len("STARTCHAR "):], False, [], None
            elif line.startswith("ENCODING"):
                enc = int(line.split()[1])
            elif line.startswith("BBX"):
                parts = line.split()
                bbx = tuple(int(x) for x in parts[1:5])  # w h xoff yoff
            elif line == "BITMAP":
                in_bitmap = True
            elif line.startswith("ENDCHAR"):
                if bbx and len(rows) == bbx[1]:
                    w, h, xo, yo = bbx
                    src_row_bytes = max(1, (w + 7) // 8)
                    if len(rows) * 2 != len("".join(rows)):
                        pass
                    buf = bytearray(GLYPH_SIZE)
                    for r, hexrow in enumerate(rows):
                        raw = bytes.fromhex(hexrow.zfill(src_row_bytes * 2))
                        # left-align into the 16-wide cell
                        buf[r * ROWBYTES:r * ROWBYTES + len(raw)] = raw[:ROWBYTES]
                    glyphs[enc] = bytes(buf)
                cur = in_bitmap = None
                rows, bbx = [], None
            elif in_bitmap and line and all(c in "0123456789abcdefABCDEF" for c in line):
                rows.append(line)
    return glyphs

def load_symbols():
    cps = set()
    try:
        with open(SYM) as f:
            for line in f:
                line = line.strip()
                if line.startswith("U+"):
                    cps.add(int(line[2:], 16))
    except FileNotFoundError:
        pass
    if not cps:
        for cp in range(0x20, 0x7F):
            cps.add(cp)
        for cp in range(0x2500, 0x2580):
            cps.add(cp)
        for cp in range(0x2190, 0x2194):
            cps.add(cp)
    return cps

def main():
    glyphs = parse_bdf(BDF)
    print("BDF glyphs parsed:", len(glyphs))
    want = load_symbols()
    print("symbols requested:", len(want))

    # position assignment
    pos = {}
    for cp in sorted(want):
        if 0x20 <= cp <= 0x7E:
            pos[cp] = cp                      # natural ASCII positions
    nxt = 0x100
    for cp in sorted(want):
        if cp in pos:
            continue
        if cp in glyphs:
            pos[cp] = nxt
            nxt += 1
    missing = [cp for cp in want if cp not in pos]
    print("mapped:", len(pos), "next position:", hex(nxt), "missing:", len(missing))
    if missing:
        print("missing sample:", [hex(c) for c in missing[:10]])
    if nxt > FONT_POSITIONS:
        print("TOO MANY POSITIONS", file=sys.stderr)
        return 1

    # glyph data: blank by default
    data = bytearray(FONT_POSITIONS * GLYPH_SIZE)
    for cp, p in pos.items():
        g = glyphs.get(cp)
        if g:
            data[p * GLYPH_SIZE:(p + 1) * GLYPH_SIZE] = g

    # unicode table: one entry per position, in order.
    # Each entry is ONE sequence: the codepoints sharing this glyph, followed
    # by a single 0xFFFF.  An unmapped position is a bare 0xFFFF.
    # (Verified against the system's own Lat7-Terminus16.psf: 'A' lands at
    # position 65, space at 32; emitting a second FFFF per entry makes
    # setfont fail with "trailing garbage".)
    # NOTE: this block is the PSF1 variant, kept for reference; the PSF2
    # table (UTF-8 + 0xFF) is built further down.
    ut_psf1 = bytearray()
    for p in range(FONT_POSITIONS):
        for cp in sorted(cp for cp, q in pos.items() if q == p):
            ut_psf1 += cp.to_bytes(2, "little")
        ut_psf1 += b"\xff\xff"

    # PSF2 header (PSF1 has no width field -- it is always read as 8px wide,
    # which smears 16px CJK glyphs into vertical strips; PSF2 stores w/h).
    # magic 0x864ab572 LE, version 0, headersize 32, flags 1 (unicode table),
    # length 512, glyphsize 32, height 16, width 16
    header = bytes([0x72, 0xb5, 0x4a, 0x86]) + \
        (0).to_bytes(4, "little") + (32).to_bytes(4, "little") + \
        (1).to_bytes(4, "little") + (FONT_POSITIONS).to_bytes(4, "little") + \
        (GLYPH_SIZE).to_bytes(4, "little") + (H).to_bytes(4, "little") + \
        (W).to_bytes(4, "little")

    # unicode table: one entry per position, in order.  PSF2 encodes the
    # codepoints as UTF-8 and terminates each entry with a single 0xFF
    # (PSF1 instead uses u16-LE codepoints + 0xFFFF -- mixing the two up
    # makes setfont fail with "trailing garbage").
    ut = bytearray()
    for p in range(FONT_POSITIONS):
        for cp in sorted(cp for cp, q in pos.items() if q == p):
            ut += chr(cp).encode("utf-8")
        ut += b"\xff"

    with open(OUT, "wb") as f:
        f.write(header)
        f.write(data)
        f.write(ut)
    print("wrote", OUT, len(header) + len(data) + len(ut), "bytes (PSF2)")
    return 0

sys.exit(main())
