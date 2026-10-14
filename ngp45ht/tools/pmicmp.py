import struct
exec(open("claims.py", encoding="utf-8").read().split("def report")[0])

def pmics(fn):
    root = load(fn)
    print("=====", fn)
    for n in walk(root):
        comp = n["props"].get("compatible", b"").decode(errors="replace")
        if "rk806" in comp or "rk808" in comp or "rk817" in comp or \
           n["__name__"].startswith("pmic@"):
            print("  PMIC %s  compatible=%s  status=%s" %
                  (n["__path__"], comp,
                   (n["props"].get("status", b"okay").rstrip(b"\0").decode())))
            for c in n["children"]:
                p = c["props"]
                nm = p.get("regulator-name", b"").rstrip(b"\0").decode()
                flags = [k for k in ("regulator-always-on", "regulator-boot-on",
                                     "regulator-off", "regulator-state-mem")
                         if k in p]
                uv = [p.get("regulator-min-microvolt"), p.get("regulator-max-microvolt")]
                uv = [struct.unpack(">I", x)[0] if x else 0 for x in uv]
                mode = p.get("regulator-mode", p.get("regulator-initial-mode"))
                print("     %-14s %-16s %5d-%5d uV  %s%s" %
                      (c["__name__"], nm, uv[0], uv[1], ",".join(flags),
                       "  mode=" + mode.hex() if mode else ""))
for fn in ("ngp.dtb", "ngpout/rk3562-ngp45ht.dtb"):
    pmics(fn)
