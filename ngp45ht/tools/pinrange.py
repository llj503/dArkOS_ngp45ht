import struct, sys
exec(open("claims.py", encoding="utf-8").read().split("def report")[0])
LO = [(1, p) for p in range(16, 32)] + [(2, p) for p in range(0, 16)]
for fn in ("ngp.dtb", "ngpout/rk3562-ngp45ht.dtb"):
    root = load(fn); nodes = walk(root)
    by_ph = dict((n["__phandle__"], n) for n in nodes if n["__phandle__"])
    print("=====", fn)
    for n in nodes:
        for k, v in n["props"].items():
            if k.startswith("pinctrl-"):
                for i in range(0, len(v) - 3, 4):
                    g = by_ph.get(struct.unpack(">I", v[i:i+4])[0])
                    if not g: continue
                    b = g["props"].get("rockchip,pins", b"")
                    hit = []
                    for j in range(0, len(b) - 15, 16):
                        bank, pin, func, conf = struct.unpack(">4I", b[j:j+16])
                        if (bank, pin) in LO:
                            cn = by_ph.get(conf); cname = cn["__name__"] if cn else "?"
                            hit.append("g%d:%d.f%d(%s)" % (bank, pin, func, cname))
                    if hit:
                        st = n["props"].get("status")
                        st = st.rstrip(b"\0").decode() if st else "(inherit)"
                        print("  %-28s owner=%-42s status=%-10s %s" %
                              (g["__name__"], n["__path__"].split("/")[-1][:42], st, " ".join(hit)))
