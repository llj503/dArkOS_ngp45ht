"""Can a pad in the suspect pin group be read back at all?

The dead key pins read 1 even with the SoC's internal pull-down enabled, which
means either (a) something external holds them high, or (b) the bank's input
receiver is blind and EXT_PORT never updates for them.

Distinguish the two by driving an *unclaimed* pin of the same group as a push-
pull output and reading its own EXT_PORT bit back.  If the bit follows the
drive, the receiver works and the problem is external wiring/matrix; if the bit
stays 1 while the SoC is actively pulling the pad low, the input path is dead.

Usage: NGP_USER=ark NGP_PW=ark python drvtest.py
"""
import os, paramiko

HOST = os.environ.get("NGP_HOST", "192.168.0.30")
USER = os.environ.get("NGP_USER", "ark")
PW = os.environ.get("NGP_PW", "ark")

SCRIPT = r'''
import mmap, os, struct, time

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
MM = {}
def rd(addr):
    off = addr & ~0xFFF
    if off not in MM:
        MM[off] = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED,
                             mmap.PROT_READ | mmap.PROT_WRITE, offset=off)
    m = MM[off]; i = addr & 0xFFF
    return struct.unpack("<I", m[i:i + 4])[0]

EXT = {1: 0xff620070, 2: 0xff630070, 0: 0xff260000 + 0x70}
# global numbers: gpio1 bank starts at 32, gpio2 at 64 on this build
TESTS = [(1, 31, 63), (1, 30, 62), (2, 5, 69)]

def bit(b, p):
    return (rd(EXT[b]) >> p) & 1

def probe(g, b, p):
    try:
        open("/sys/class/gpio/export", "w").write("%d\n" % g)
    except Exception as e:
        print("  gpio%d export failed: %s" % (g, e)); return
    d = "/sys/class/gpio/gpio%d/" % g
    try:
        open(d + "direction", "w").write("out\n")
        for lvl in (0, 1, 0):
            open(d + "value", "w").write("%d\n" % lvl)
            time.sleep(0.05)
            print("  g%d_%s%d driven %d -> ext_port reads %d  (ddr=%d dr=%d)" %
                  (b, "ABCD"[p // 8], p % 8, lvl, bit(b, p),
                   (rd(EXT[b] - 0x70 + 0x08) >> p) & 1,
                   (rd(EXT[b] - 0x70 + 0x00) >> p) & 1))
            time.sleep(0.05)
    finally:
        try:
            open(d + "direction", "w").write("in\n")
        except Exception:
            pass
        open("/sys/class/gpio/unexport", "w").write("%d\n" % g)

for b, p, g in TESTS:
    probe(g, b, p)
print("baseline ext: b0=%08x b1=%08x b2=%08x" %
      (rd(EXT[0]), rd(EXT[1]), rd(EXT[2])))
'''

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PW, timeout=30,
          allow_agent=False, look_for_keys=False)
c.exec_command("cat > /tmp/drvtest.py << 'PYEOF'\n" + SCRIPT + "\nPYEOF", timeout=60)
i, o, e = c.exec_command("echo %s | sudo -S -p '' sh -c 'python3 /tmp/drvtest.py'" % PW,
                         timeout=120)
print(o.read().decode(errors="replace"))
err = e.read().decode(errors="replace")
if err.strip():
    print("[stderr]", err[:600])
c.close()
