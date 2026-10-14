"""Dump RK3562 ioc_grf pinmux/pull/smt/drv + GPIO bank regs.

Run against whichever OS is currently booted; the numbers are pure hardware
state, so stock and dArkOS dumps are directly comparable.

ioc_grf = 0xff060000 (phandle target of rockchip,grf in rk3562.dtsi).
Register math mirrors drivers/pinctrl/pinctrl-rockchip.c rk3562_* helpers:
  mux  4 bits/pin, 4 pins per 32-bit reg, bank bases gpio1 0x00 gpio2 0x20
       gpio3 0x10040, gpio0 0x20000
  pull 2 bits/pin, 8 pins per reg, gpio0 0x20020 gpio1 0x80 gpio2 0x90 gpio3 0x100A0
  smt  2 bits/pin, 8 pins per reg, gpio0 0x20030 gpio1 0xC0 gpio2 0xD0 gpio3 0x100E0
  drv  8 bits/pin, 2 pins per reg, gpio0 0x20070 gpio1 0x200 gpio2 0x240 gpio3 0x10280

Usage: python grfcmp.py            (stock EmuELEC)
       NGP_USER=ark NGP_PW=ark python grfcmp.py   (dArkOS)
"""
import sys, os, paramiko

HOST = os.environ.get("NGP_HOST", "192.168.0.30")
USER = os.environ.get("NGP_USER", "root")
PW = os.environ.get("NGP_PW", "emuelec")
SUDO = os.environ.get("NGP_SUDO", "1") == "1"

PAYLOAD = r'''
import mmap, struct, os
IOC = __IOC__
BANK = __BANK__
MUX, PULL, SMT, DRV = __MUX__, __PULL__, __SMT__, __DRV__
USED = set(__USED__)
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
_cache = {}

def rd(addr):
    off = addr & ~0xFFF
    mm = _cache.get(off)
    if mm is None:
        mm = _cache[off] = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED,
                                     mmap.PROT_READ, offset=off)
    i = addr & 0xFFF
    return struct.unpack("<I", mm[i:i + 4])[0]

def mux_of(b, p):
    reg = IOC + MUX[b] + (p // 8) * 8 + (4 if p % 8 >= 4 else 0)
    return (rd(reg) >> ((p % 4) * 4)) & 0xF

def pull_of(b, p):
    return (rd(IOC + PULL[b] + (p // 8) * 4) >> ((p % 8) * 2)) & 3

def smt_of(b, p):
    return (rd(IOC + SMT[b] + (p // 8) * 4) >> ((p % 8) * 2)) & 3

def drv_of(b, p):
    return (rd(IOC + DRV[b] + (p // 2) * 4) >> ((p % 2) * 8)) & 0xFF

NAMES = "ABCD"
def tag(b, p):
    return "g%d_%s%d" % (b, NAMES[p // 8], p % 8)

for b in (0, 1, 2, 3):
    other = [tag(b, p) for p in range(32)
             if mux_of(b, p) != 0 and (b, p) not in USED]
    print("### bank%d mux!=GPIO, not our keys (%d): %s" %
          (b, len(other), " ".join(other) or "-"))
    for p in range(32):
        if (b, p) in USED:
            print("   %-9s mux=%d pull=%d smt=%d drv=%02x ext_port_bit=%d" %
                  (tag(b, p), mux_of(b, p), pull_of(b, p), smt_of(b, p),
                   drv_of(b, p), (rd(BANK[b] + 0x70) >> p) & 1))

print("=== GPIO bank regs ===")
for b in sorted(BANK):
    base = BANK[b]
    names = (("dr", 0x00), ("ddr", 0x08), ("int_en", 0x10), ("int_mask", 0x18),
             ("int_type", 0x20), ("int_pol", 0x28), ("bothedge", 0x30),
             ("debounce", 0x38), ("ext_port", 0x70), ("ver", 0x78))
    print("gpio%d " % b + " ".join("%s=%08x" % (n, rd(base + o)) for n, o in names))

print("=== clock gates / selects ===")
CRU = (("pmu0_con0", 0xff110180, "g0_pclk=9 g0_dbclk=10"),
       ("cru_con20", 0xff100350, "dclk_gpio3=5"),
       ("cru_con26", 0xff100368, "pclk_gpio3=2 pclk_gpio4=3"),
       ("peri_con16", 0xff130340, "pclk_saradc=4 ioc_vccio234=12"),
       ("peri_con17", 0xff130344, "pclk_g1=0 pclk_g2=1 dclk_g1=2 dclk_g2=3 dclk_peri_gpio=4"),
       ("peri_sel47", 0xff1301bc, "dclk_peri_gpio_src=8"))
for name, addr, bits in CRU:
    v = rd(addr)
    lo = v & 0xFFFF
    dec = " ".join("%s=%d" % (k, (lo >> int(n)) & 1)
                   for k, n in (p.split("=") for p in bits.split()))
    print("%-10s %08x  set=%04x   %s" % (name, v, lo, dec))
'''

USED = [(0, 5), (0, 11), (0, 12), (0, 13), (0, 14), (0, 15), (0, 19), (0, 21),
        (0, 22), (0, 23), (1, 23), (1, 24), (1, 25), (1, 26), (1, 27), (1, 28),
        (2, 0), (2, 1), (3, 6)]


def main():
    src = (PAYLOAD
           .replace("__IOC__", hex(0xff060000))
           .replace("__BANK__", repr({0: 0xff260000, 1: 0xff620000,
                                      2: 0xff630000, 3: 0xffac0000}))
           .replace("__MUX__", repr({0: 0x20000, 1: 0x00, 2: 0x20, 3: 0x10040}))
           .replace("__PULL__", repr({0: 0x20020, 1: 0x80, 2: 0x90, 3: 0x100A0}))
           .replace("__SMT__", repr({0: 0x20030, 1: 0xC0, 2: 0xD0, 3: 0x100E0}))
           .replace("__DRV__", repr({0: 0x20070, 1: 0x200, 2: 0x240, 3: 0x10280}))
           .replace("__USED__", repr(sorted(USED))))
    assert "__" not in src

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PW, timeout=30,
              allow_agent=False, look_for_keys=False)
    c.exec_command("cat > /tmp/grfdump.py << 'PYEOF'\n" + src + "\nPYEOF", timeout=60)
    cmd = "python3 /tmp/grfdump.py"
    if USER != "root":
        cmd = "echo %s | sudo -S -p '' sh -c 'python3 /tmp/grfdump.py'" % PW
    i, o, e = c.exec_command(cmd, timeout=120)
    out = o.read().decode(errors="replace")
    sys.stdout.buffer.write(out.encode("ascii", "replace"))
    err = e.read().decode(errors="replace")
    if err.strip():
        sys.stdout.buffer.write(("[stderr] " + err).encode("ascii", "replace"))
    c.close()


main()
