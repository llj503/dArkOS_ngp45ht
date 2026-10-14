"""Which enabled DT nodes claim the dead key pins?

For every node that is not status="disabled", collect
  - pinctrl-<n>  -> group nodes -> rockchip,pins (bank, pin, func, conf)
  - *-gpios / *-gpio properties -> (phandle-parent, pin) pairs, only when the
    parent is a gpio-controller
and report every claim on the pins that are dead under dArkOS, plus a couple of
working pins for contrast.

Usage: python claims.py <dtb> [dtb...]
"""
import struct, sys

TARGETS = {(1, 23): "MODE(C7)", (1, 25): "L1(D1)", (1, 26): "L2(D2)",
           (1, 27): "R1(D3)", (1, 28): "R2(D4)", (2, 0): "X(A0)",
           (2, 1): "Y(A1)", (0, 21): "ok:C5", (0, 23): "ok:C7",
           (3, 6): "ok:A6", (1, 24): "sdmmc1-det(D0)", (1, 22): "sdmmc1-clk(C6)"}


def load(fn):
    d = open(fn, "rb").read()
    magic, total, ostruct, ostr = struct.unpack(">4I", d[:16])
    al = lambda x: (x + 3) & ~3

    def st(o):
        e = d.index(b"\0", ostr + o)
        return d[ostr + o:e].decode()

    root = {"__name__": "/", "props": {}, "children": [], "__phandle__": None}
    stack, cur, p = [], root, ostruct
    while p < total:
        tok = struct.unpack(">I", d[p:p + 4])[0]; p = al(p + 4)
        if tok == 1:
            e = d.index(b"\0", p); nm = d[p:e].decode(); p = al(e + 1)
            n = {"__name__": nm or "/", "props": {}, "children": [],
                 "__phandle__": None, "__parent__": cur}
            cur["children"].append(n); stack.append(cur); cur = n
        elif tok == 2:
            cur = stack.pop()
        elif tok == 3:
            ln, no = struct.unpack(">2I", d[p:p + 8]); p = al(p + 8)
            cur["props"][st(no)] = d[p:p + ln]; p = al(p + ln)
        elif tok == 9:
            break
    return root


def walk(n, out=None):
    out = out if out is not None else []
    n["__path__"] = (n.get("__parent__", {}).get("__path__", "") or "") + "/" + n["__name__"]
    ph = n["props"].get("phandle")
    if ph:
        n["__phandle__"] = struct.unpack(">I", ph)[0]
    out.append(n)
    for c in n["children"]:
        walk(c, out)
    return out


def enabled(n):
    while n is not None:
        s = n["props"].get("status")
        if s is not None and s.rstrip(b"\0").decode() != "okay":
            return False
        n = n.get("__parent__")
    return True


def cells(n, prop, default):
    v = n["props"].get(prop)
    return struct.unpack(">I", v)[0] if v else default


def report(fn):
    root = load(fn)
    nodes = walk(root)
    by_ph = dict((n["__phandle__"], n) for n in nodes if n["__phandle__"])
    print("===== %s =====" % fn)
    hits = {}
    for n in nodes:
        if not enabled(n):
            continue
        path = n["__path__"]
        for k, v in n["props"].items():
            claims = []
            if k.startswith("pinctrl-"):
                for i in range(0, len(v) - 3, 4):
                    g = by_ph.get(struct.unpack(">I", v[i:i + 4])[0])
                    if not g:
                        continue
                    b = g["props"].get("rockchip,pins", b"")
                    for j in range(0, len(b) - 15, 16):
                        bank, pin, func, conf = struct.unpack(">4I", b[j:j + 16])
                        claims.append((bank, pin, "func%d" % func))
            elif k.endswith("gpios") or k.endswith("gpio"):
                par = by_ph.get(struct.unpack(">I", v[0:4])[0]) if len(v) >= 4 else None
                if par is None or "gpio-controller" not in par["props"]:
                    continue
                nc = cells(par, "#gpio-cells", 2)
                for j in range(0, len(v) - 4 * nc + 4, 4 * nc):
                    p2 = struct.unpack(">%dI" % nc, v[j:j + 4 * nc])
                    if p2[0] != par["__phandle__"]:
                        continue
                    reg = par["props"].get("reg")
                    cs = struct.unpack(">%dI" % (len(reg) // 4), reg) if reg else ()
                    base = cs[-2] if len(cs) >= 2 else 0
                    gbank = {0xff260000: 0, 0xff620000: 1, 0xff630000: 2,
                             0xffac0000: 3}.get(base, -1)
                    claims.append((gbank, p2[1], "gpio-in"))
            for c in claims:
                if c[:2] in TARGETS:
                    hits.setdefault(c[:2], []).append((path, k, c[2]))
    for (bank, pin), who in sorted(hits.items()):
        print("  g%d_%s(%d) [%s]" % (bank, "ABCD"[pin // 8] + str(pin % 8), pin,
                                     TARGETS[(bank, pin)]))
        for path, k, f in who:
            print("      %-70s via %-18s %s" % (path[:70], k, f))


for fn in sys.argv[1:] or ["ngp.dtb", "ngpout/rk3562-ngp45ht.dtb"]:
    try:
        report(fn)
    except Exception as e:
        if "-v" in sys.argv:
            import traceback; traceback.print_exc()
        print(fn, "failed:", type(e).__name__, e)
