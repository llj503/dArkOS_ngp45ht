import re, sys

SRC = '/home/ark/dtbwork/ngp.dts'
OUT = '/home/ark/dtbwork/ngp-new2.dts'

s = open(SRC, encoding='utf-8').read()

# ---- 0. 安全检查：GPIO3 pin 12/13/15 是否被别的 pinctrl 组占用 ----
hits = []
for m in re.finditer(r'rockchip,pins = <([^>]*)>', s):
    vals = m.group(1).split()
    for i in range(0, len(vals) - 3, 4):
        bank, pin = vals[i], vals[i+1]
        if bank == '0x03' and pin in ('0x0c', '0x0d', '0x0f'):
            ctx = s[max(0, m.start()-400):m.start()]
            nm = re.findall(r'\n\t+([A-Za-z0-9_\-]+) \{', ctx)
            hits.append((nm[-1] if nm else '?', bank, pin))
print("GPIO3 pin 12/13/15 现有占用:", hits)

# ---- 1. 分配新 phandle ----
mx = max(int(x, 16) for x in re.findall(r'phandle = <0x([0-9a-fA-F]+)>', s))
p1, p2 = mx + 1, mx + 2
print("max phandle = 0x%x -> new 0x%x 0x%x" % (mx, p1, p2))

def block_end(text, start_idx):
    """给定 '{' 所在索引，返回匹配的 '}' 索引"""
    d = 0
    i = start_idx
    while i < len(text):
        if text[i] == '{':
            d += 1
        elif text[i] == '}':
            d -= 1
            if d == 0:
                return i
        i += 1
    raise RuntimeError('unbalanced')

# ---- 2. 在 pinctrl 的 spi0 组后面插入 spi0-ngp45h ----
m = re.search(r'\n\t\tspi0 \{\n', s)
assert m, 'pinctrl spi0 group not found'
gstart = s.index('{', m.start())
gend = block_end(s, gstart)
# 找到该组结束后的分号之后
semi = s.index(';', gend)
ins_at = semi + 1
newgroup = (
    '\n\n\t\tspi0-ngp45h {\n'
    '\n\t\t\tspi0m1-csn0-ngp45h {\n'
    '\t\t\t\trockchip,pins = <0x03 0x0f 0x04 0xd5>;\n'
    '\t\t\t\tphandle = <0x%x>;\n' % p1 +
    '\t\t\t};\n'
    '\n\t\t\tspi0m1-pins-ngp45h {\n'
    '\t\t\t\trockchip,pins = <0x03 0x0d 0x04 0xd5 0x03 0x0c 0x04 0xd5>;\n'
    '\t\t\t\tphandle = <0x%x>;\n' % p2 +
    '\t\t\t};\n'
    '\t\t};'
)
s = s[:ins_at] + newgroup + s[ins_at:]
print("inserted spi0-ngp45h pinctrl group")

# ---- 3. 改 spi@ff220000 ----
m = re.search(r'\n\tspi@ff220000 \{\n', s)
assert m, 'spi@ff220000 not found'
gstart = s.index('{', m.start())
gend = block_end(s, gstart)
node = s[gstart:gend + 1]
new = node.replace('pinctrl-0 = <0x4c 0x4d 0x4e>;',
                   'pinctrl-0 = <0x%x 0x%x>;' % (p1, p2))
assert new != node, 'pinctrl-0 not replaced'
new = new.replace('status = "disabled";', 'status = "okay";')
assert 'status = "okay"' in new
child = ('\n\n\t\tspi_dev@0 {\n'
         '\t\t\tcompatible = "rockchip,spidev";\n'
         '\t\t\treg = <0x00>;\n'
         '\t\t\tspi-max-frequency = <0x7a1200>;\n'
         '\t\t};')
new = new[:-1].rstrip() + '\n' + child + '\n\t}'
s = s[:gstart] + new + s[gend + 1:]
print("patched spi@ff220000")

# ---- 4. __symbols__ 加两项 ----
m = re.search(r'\n\t__symbols__ \{\n', s)
if m:
    gstart = s.index('{', m.start())
    gend = block_end(s, gstart)
    add = ('\t\tspi0m1_csn0_ngp45h = "/pinctrl/spi0-ngp45h/spi0m1-csn0-ngp45h";\n'
           '\t\tspi0m1_pins_ngp45h = "/pinctrl/spi0-ngp45h/spi0m1-pins-ngp45h";\n')
    s = s[:gend] + add + s[gend:]
    print("added __symbols__ entries")

open(OUT, 'w', encoding='utf-8').write(s)
print("wrote", OUT, len(s), "bytes")
