"""Regenerate rk3562-ngp45ht.dts.tpl from the authoritative DTS in the kernel tree,
restoring the two placeholders so gen_dts.py stays usable."""
import re, sys

DTS = r"F:\darkos\kernel_rk3562\arch\arm64\boot\dts\rockchip\rk3562-ngp45ht.dts"
TPL = r"F:\darkos\_work\rk3562-ngp45ht.dts.tpl"

s = open(DTS, encoding="utf-8").read()

# panel-init-sequence = [ ...hex rows... ];
pat = re.compile(r"(\tpanel-init-sequence = \[\n)(.*?)(\t\];\n)", re.S)
m = pat.search(s)
assert m, "panel-init-sequence block not found"
rows = m.group(2).rstrip("\n").split("\n")
assert rows and re.fullmatch(r"\t\t[0-9a-f ]+", rows[0]), repr(rows[0])
s = s[:m.start()] + m.group(1) + "@@PANEL_INIT_SEQUENCE@@\n" + m.group(3) + s[m.end():]

# ocv_table = < ... >;
pat2 = re.compile(r"(\t\tocv_table = )<[^>]*>(;)")
m2 = pat2.search(s)
assert m2, "ocv_table not found"
s = s[:m2.start()] + m2.group(1) + "@@OCV_TABLE@@" + m2.group(2) + s[m2.end():]

assert s.count("@@PANEL_INIT_SEQUENCE@@") == 1 and s.count("@@OCV_TABLE@@") == 1
open(TPL, "w", encoding="utf-8", newline="\n").write(s)
print("template refreshed: %d lines, %d bytes" % (s.count("\n") + 1, len(s)))
