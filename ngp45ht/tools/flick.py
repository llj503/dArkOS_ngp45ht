"""Flick LDO_REG8's enable bit and sample the pads in the same breath.

The regulator core re-writes POWER_EN2 (0xb3) whenever it gets a chance, so a
single write-then-read a second later reads back as if nothing happened.  Read
the pad registers inside the same loop iteration instead: if the pads in the
suspect IO group are merely unpowered, they will move the moment the rail comes
up (all of them currently have the SoC's internal pull-down enabled, so a
powered pad must read 0).
"""
import os, sys, paramiko

HOST = os.environ.get("NGP_HOST", "192.168.0.30")
USER = os.environ.get("NGP_USER", "ark")
PW = os.environ.get("NGP_PW", "ark")

SCRIPT = r'''
import mmap, os, struct, time, fcntl

fd = os.open("/dev/i2c-0", os.O_RDWR)
fcntl.ioctl(fd, 0x0706, 0x20)

mem = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
MM = {}
def rd32(addr):
    off = addr & ~0xFFF
    if off not in MM:
        MM[off] = mmap.mmap(mem, 0x1000, mmap.MAP_SHARED,
                             mmap.PROT_READ | mmap.PROT_WRITE, offset=off)
    m = MM[off]; i = addr & 0xFFF
    return struct.unpack("<I", m[i:i + 4])[0]

def poke(reg, val):
    os.write(fd, bytes([reg, val]))

def peek(reg):
    os.write(fd, bytes([reg]))
    return os.read(fd, 1)[0]

base1 = rd32(0xff620070)
base2 = rd32(0xff630070)
print("idle ext b1=%08x b2=%08x  POWER_EN2=%02x" % (base1, base2, peek(0xb3)))
hits = 0
poke(0xb3, 0x0F)                     # bit3 = LDO_REG8 on, bits0-2 as found
for i in range(120):
    v = peek(0xb3)
    b1 = rd32(0xff620070)
    b2 = rd32(0xff630070)
    if v != 0x07 or b1 != base1 or b2 != base2:
        hits += 1
        if hits <= 12:
            print("  iter %3d en=%02x b1=%08x b2=%08x  d1=%08x d2=%08x" %
                  (i, v, b1, b2, b1 ^ base1, b2 ^ base2))
    if i % 10 == 0:
        poke(0xb3, 0x0F)
    time.sleep(0.002)
print("done: %d iterations showed a change" % hits)
print("final ext b1=%08x b2=%08x en=%02x" % (rd32(0xff620070), rd32(0xff630070),
                                              peek(0xb3)))
'''

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PW, timeout=30,
          allow_agent=False, look_for_keys=False)
c.exec_command("cat > /tmp/flick.py << 'PYEOF'\n" + SCRIPT + "\nPYEOF", timeout=60)
i, o, e = c.exec_command("echo %s | sudo -S -p '' sh -c 'python3 /tmp/flick.py'" % PW,
                         timeout=180)
print(o.read().decode(errors="replace"))
err = e.read().decode(errors="replace")
if err.strip():
    print("[stderr]", err[:500])
c.close()
