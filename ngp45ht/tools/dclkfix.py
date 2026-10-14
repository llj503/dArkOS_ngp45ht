"""Turn the gated-off GPIO1/GPIO2 dclk back on and watch for key events.

Root cause candidate: dArkOS's late_initcall clk_disable_unused closes
DCLK_PERI_GPIO (PERI CLKGLF CON17 bit 4) and its children DCLK_PERI_GPIO1/2
(bits 2/3) at 0xff130344.  Stock leaves all three open.  With the dclk off the
bank's input synchroniser never sees an edge, so every key on GPIO1/GPIO2 reads
frozen at its idle level while mux/pull/direction are all correct.

This script opens the three bits, then logs both the raw ext_port registers and
the joystick evdev stream so one held key press settles it.

Usage: NGP_USER=ark NGP_PW=ark python dclkfix.py
"""
import os, sys, time, paramiko

HOST = os.environ.get("NGP_HOST", "192.168.0.30")
USER = os.environ.get("NGP_USER", "ark")
PW = os.environ.get("NGP_PW", "ark")

REMOTE = r'''
import mmap, os, struct, sys, time, glob

fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
MM = {}
def mp(addr):
    off = addr & ~0xFFF
    if off not in MM:
        MM[off] = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED,
                             mmap.PROT_READ | mmap.PROT_WRITE, offset=off)
    return MM[off], addr & 0xFFF

def rd(addr):
    m, i = mp(addr)
    return struct.unpack("<I", m[i:i + 4])[0]

def wr_set(addr, bits):
    m, i = mp(addr)
    m[i:i + 4] = struct.pack("<I", (bits << 16) | bits)

GATE = 0xff130344
print("before  %08x" % rd(GATE))
wr_set(GATE, 0x1C)                     # bits 2 dclk_g1, 3 dclk_g2, 4 dclk_peri_gpio
print("after   %08x" % rd(GATE))

EXT = {1: 0xff620070, 2: 0xff630070, 0: 0xff260070}
dev = None
for p in glob.glob("/dev/input/by-path/*joystick*"):
    dev = p
print("event device: %s" % dev)

log = open("/tmp/dclk.log", "w", buffering=1)
fd_ev = os.open(dev, os.O_RDONLY | os.O_NONBLOCK) if dev else None
T0 = time.time()
log.write("start gate=%08x\n" % rd(GATE))
while time.time() - T0 < 300:
    for b, a in EXT.items():
        v = rd(a)
        key = "b%d" % b
        if v != getattr(watch, key, None):
            log.write("%.3f ext b%d=%08x\n" % (time.time() - T0, b, v))
            setattr(watch, key, v)
    if fd_ev is not None:
        try:
            data = os.read(fd_ev, 4 * 24)
        except BlockingIOError:
            data = b""
        for i in range(0, len(data) - 23, 24):
            s, us, typ, code, val = struct.unpack("qqHHi", data[i:i + 24])
            log.write("%.3f EV type=%d code=%d val=%d\n" %
                      (time.time() - T0, typ, code, val))
    time.sleep(0.02)
log.write("DONE\n")
'''


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PW, timeout=30,
              allow_agent=False, look_for_keys=False)

    def sh(cmd, t=120):
        full = "echo %s | sudo -S -p '' sh -c %s" % (
            PW, "'" + cmd.replace("'", "'\"'\"'") + "'")
        i, o, e = c.exec_command(full, timeout=t)
        return o.read().decode(errors="replace"), e.read().decode(errors="replace")

    # prepend the class shim the watcher uses to remember previous values
    body = "class watch:\n    pass\n" + REMOTE
    c.exec_command("cat > /tmp/dclkfix.py << 'PYEOF'\n" + body + "\nPYEOF", timeout=60)
    out, err = sh("(nohup python3 /tmp/dclkfix.py > /tmp/dclkfix.out 2>&1 &) ; sleep 4; "
                  "cat /tmp/dclkfix.out")
    print("### gate write + watcher start\n" + out)
    if err.strip():
        print("[stderr]", err[:300])
    c.close()


main()
