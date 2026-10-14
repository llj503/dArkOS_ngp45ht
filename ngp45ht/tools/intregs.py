"""Dump the full v2 GPIO interrupt register set (both halves) per bank.

gpio-rockchip.c uses gpio_writel_v2(), which writes the low 16 pins to `reg`
and the high 16 pins to `reg + 4`.  The C/D groups of gpio1 are in the *high*
half, so a dump of only the low words says nothing about the shoulder keys.
"""
import os, paramiko

HOST = os.environ.get("NGP_HOST", "192.168.0.30")
USER = os.environ.get("NGP_USER", "ark")
PW = os.environ.get("NGP_PW", "ark")

SCRIPT = r'''
import mmap, os, struct
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
MM = {}
def rd(a):
    off = a & ~0xFFF
    if off not in MM:
        MM[off] = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED,
                             mmap.PROT_READ | mmap.PROT_WRITE, offset=off)
    m = MM[off]; i = a & 0xFFF
    return struct.unpack("<I", m[i:i + 4])[0]

BASE = {0: 0xff260000, 1: 0xff620000, 2: 0xff630000, 3: 0xffac0000}
# (name, offset) pairs: low word covers pins 0-15, high word (+4) pins 16-31
REGS = (("int_en", 0x10), ("int_mask", 0x18), ("int_type", 0x20),
        ("int_pol", 0x28), ("bothedge", 0x30), ("int_status", 0x50),
        ("raw_status", 0x58), ("eoi", 0x60), ("ext_port", 0x70))
WATCH = {0: 21, 1: 25, 2: 0, 3: 6}
for b in sorted(BASE):
    print("bank%d" % b)
    for name, off in REGS:
        lo = rd(BASE[b] + off)
        hi = rd(BASE[b] + off + 0x04) if name != "ext_port" else lo
        tag = ""
        p = WATCH[b]
        half = hi if p >= 16 and name != "ext_port" else lo
        if name in ("int_en", "int_mask", "bothedge", "int_status", "raw_status"):
            tag = "  [pin%d bit=%d]" % (p, (half >> (p % 16)) & 1)
        print("   %-11s lo=%08x hi=%08x%s" % (name, lo, hi, tag))
'''

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PW, timeout=30,
          allow_agent=False, look_for_keys=False)
c.exec_command("cat > /tmp/intregs.py << 'PYEOF'\n" + SCRIPT + "\nPYEOF", timeout=60)
i, o, e = c.exec_command("echo %s | sudo -S -p '' sh -c 'python3 /tmp/intregs.py'" % PW,
                         timeout=120)
print(o.read().decode(errors="replace"))
err = e.read().decode(errors="replace")
if err.strip():
    print("[stderr]", err[:400])
c.close()
