"""Generate rk3562-ngp45ht.dts, pulling the panel DSI sequence from the
stock DTB so the bytes are exact rather than hand-transcribed."""
import struct, sys, os

sys.argv = ["dtb", "ngp.dtb"]
src = open("dtb.py", encoding="utf-8").read().split("for target in")[0]
exec(src)

panel = None
def find_panel(n):
    global panel
    if n["__name__"].startswith("panel@") and b"simple-panel-dsi" in n["props"].get("compatible", b""):
        panel = n
        return True
    for c in n["children"]:
        if find_panel(c):
            return True
    return False

find_panel(root)
seq = panel["props"]["panel-init-sequence"]

# Each command is [data-type, data-delay, data-length, <data...>], so entries
# are variable width -- walk the length byte instead of assuming 5.
rows, i = [], 0
while i < len(seq):
    ln = seq[i + 2]
    rows.append(seq[i:i + 3 + ln].hex(" "))
    i += 3 + ln
assert i == len(seq), (i, len(seq))
body = "\n".join("\t\t" + r for r in rows)

bat = None
def find_batt(n):
    global bat
    if b"rk817,battery" in n["props"].get("compatible", b""):
        bat = n
        return True
    for c in n["children"]:
        if find_batt(c):
            return True
    return False

find_batt(root)
ocv = struct.unpack(">%dI" % (len(bat["props"]["ocv_table"]) // 4),
                    bat["props"]["ocv_table"])
assert 20 <= len(ocv) <= 24, len(ocv)
print("ocv entries: %d  (%d..%d mV)" % (len(ocv), ocv[0], ocv[-1]))
ocv_str = "<" + " ".join(str(v) for v in ocv) + ">"

tpl = open("rk3562-ngp45ht.dts.tpl", encoding="utf-8").read()
out = tpl.replace("@@PANEL_INIT_SEQUENCE@@", body).replace("@@OCV_TABLE@@", ocv_str)
assert "@@" not in out, "unsubstituted placeholder left"
dest = r"F:\darkos\kernel_rk3562\arch\arm64\boot\dts\rockchip\rk3562-ngp45ht.dts"
open(dest, "w", encoding="utf-8", newline="\n").write(out)
print("panel init: %d bytes / %d commands" % (len(seq), len(rows)))
print("wrote", dest, os.path.getsize(dest), "bytes")
