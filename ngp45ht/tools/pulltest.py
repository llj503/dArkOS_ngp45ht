"""Pull the floating pads next to the dead keys down and see if the pads follow.

Stock reads gpio1 D0/D5/D6/D7 at 0 while dArkOS reads them at 1, and stock has
those pads muxed to sdmmc1/RMII functions (dArkOS leaves them as unclaimed
GPIOs, hence high-impedance).  If the shoulder/X/Y/MODE keys return through one
of those pads instead of ground, the floating-high state would hide every press.

Step 1 (no press needed): switch all four to internal pull-down and read the
pads back.  If a pad drops to 0 the input path is alive and the pad is not
driven; if it stays 1 something is actively holding it high.

Usage: NGP_USER=ark NGP_PW=ark python pulltest.py <set|restore>
"""
import os, sys, paramiko

HOST = os.environ.get("NGP_HOST", "192.168.0.30")
USER = os.environ.get("NGP_USER", "ark")
PW = os.environ.get("NGP_PW", "ark")
MODE = sys.argv[1] if len(sys.argv) > 1 else "set"

# bank, pin  -> global gpio number = 32*bank + pin for gpio1
PINS = [(1, 23), (1, 25), (1, 26), (1, 27), (1, 28), (2, 0), (2, 1),
        (1, 24), (1, 29), (1, 30), (1, 31)]
PULL = {0: 0x20020, 1: 0x80, 2: 0x90, 3: 0x100A0}

SCRIPT = r'''
import mmap, os, struct, sys

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
MM = {}
def mp(addr):
    off = addr & ~0xFFF
    if off not in MM:
        MM[off] = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED,
                             mmap.PROT_READ | mmap.PROT_WRITE, offset=off)
    return MM[off], addr & 0xFFF

def rd(a):
    m, i = mp(a)
    return struct.unpack("<I", m[i:i + 4])[0]

def wm(a, mask, val):
    # RK3562 IOC GRF uses the upper-16-bit write-enable convention: bits [31:16]
    # are a strobe for bits [15:0], so a plain read-modify-write does nothing.
    m, i = mp(a)
    m[i:i + 4] = struct.pack("<I", ((mask & 0xFFFF) << 16) | (val & mask))

IOC = 0xff060000
PULL = {0: 0x20020, 1: 0x80, 2: 0x90, 3: 0x100A0}
MUX = {0: 0x20000, 1: 0x00, 2: 0x20, 3: 0x10040}
EXT = {0: 0xff260070, 1: 0xff620070, 2: 0xff630070, 3: 0xffac0070}
WANT_MUX = __MUXADDR__
PULLADDR = __PULL__
PULLBIT = __PULLBIT__
PINS = __PINS__
VAL = __VAL__

def mux_addr(b, p):
    return IOC + MUX[b] + (p // 8) * 8 + (4 if p % 8 >= 4 else 0)

def mux_val(b, p):
    return (rd(mux_addr(b, p)) >> ((p % 4) * 4)) & 0xF

def show(tag):
    for b, p in PINS:
        e = (rd(EXT[b]) >> p) & 1
        print("  g%d_%s%d mux=%d pull=%d ext=%d" %
              (b, "ABCD"[p // 8], p % 8, mux_val(b, p),
               (rd(IOC + PULLADDR[b] + (p // 8) * 4) >> ((p % 8) * 2)) & 3, e))
    sys.stdout.flush()

print("BEFORE (restore=%d)" % (VAL == 1))
show("before")
for b, p in PINS:
    a = IOC + PULLADDR[b] + (p // 8) * 4
    bit = (p % 8) * 2
    wm(a, 3 << bit, VAL << bit)
print("AFTER setting pull=%d" % VAL)
show("after")
'''


def main():
    # pull value: 3 = pull-down for the experiment, 1 = disable when restoring
    val = 1 if MODE == "restore" else 3
    src = (SCRIPT
           .replace("__MUXADDR__", "{}")
           .replace("__PULL__", repr(PULL))
           .replace("__PULLBIT__", "{}")
           .replace("__PINS__", repr(PINS))
           .replace("__VAL__", repr(val)))
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PW, timeout=30,
              allow_agent=False, look_for_keys=False)
    c.exec_command("cat > /tmp/pulltest.py << 'PYEOF'\n" + src + "\nPYEOF", timeout=60)
    cmd = ("echo %s | sudo -S -p '' sh -c 'python3 /tmp/pulltest.py'" % PW)
    i, o, e = c.exec_command(cmd, timeout=120)
    out = o.read().decode(errors="replace")
    err = e.read().decode(errors="replace")
    print("### pull %s (%s)\n%s" % (MODE, val, out))
    if err.strip():
        print("[stderr]", err[:600])
    c.close()


main()
