"""Read/toggle RK817 PMIC registers over I2C from userspace.

On this board the vendor DT keeps LDO_REG8 at 3.3 V always-on+boot-on, while the
dArkOS shared dtsi leaves it at 1.8 V with no always-on, so the regulator core
disables it as unused.  LDO_REG8 is the only rail difference between the two
device trees, and the pad group it plausibly feeds is exactly the region that
reads dead under dArkOS: gpio1 C1..C7 + D0..D7 (TF2's sdmmc1 and the six
shoulder/face keys plus MODE) and gpio2 A0/A1 (X/Y).

RK817 LDO_REG8 per drivers/regulator/rk808-regulator.c:
  enable  = POWER_EN_REG(2) = 0xb3, BIT(3)
  voltage = LDO_ON_VSEL_REG(7) = 0xda, 600..3400 mV in 25 mV steps

Usage: python pmic_i2c.py            # read only
       python pmic_i2c.py on         # set 3.3 V and enable LDO_REG8
"""
import os, sys, paramiko

HOST = os.environ.get("NGP_HOST", "192.168.0.30")
USER = os.environ.get("NGP_USER", "ark")
PW = os.environ.get("NGP_PW", "ark")
ACTION = sys.argv[1] if len(sys.argv) > 1 else "read"

SCRIPT = r'''
import os, struct, sys, fcntl

I2C_SLAVE_FORCE = 0x0706
ADDR = 0x20
ACT = "__ACTION__"

bus = None
for n in range(4):
    p = "/dev/i2c-%d" % n
    if os.path.exists(p):
        bus = p
        break
print("bus:", bus)
fd = os.open(bus, os.O_RDWR)
fcntl.ioctl(fd, I2C_SLAVE_FORCE, ADDR)

def wr(reg, val):
    os.write(fd, bytes([reg, val]))

def rd(reg):
    os.write(fd, bytes([reg]))      # address pointer only; a second byte here
    return os.read(fd, 1)[0]        # would be a WRITE to that PMIC register

for r, name in ((0xb3, "POWER_EN2"), (0xda, "LDO8_ON_VSEL"),
                (0xdb, "LDO8_OFF_VSEL"), (0xb1, "POWER_EN0"),
                (0xb2, "POWER_EN1"), (0xb4, "POWER_EN3")):
    print("  0x%02x %-13s = %02x" % (r, name, rd(r)))

if ACT == "on":
    v = rd(0xb3)
    wr(0xb3, v | 0x08)
    wr(0xda, (3300 - 600) // 25)      # 3.30 V
    print("after enable: POWER_EN2=%02x LDO8_VSEL=%02x (%d mV)" %
          (rd(0xb3), rd(0xda), 600 + 25 * rd(0xda)))
'''

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PW, timeout=30,
          allow_agent=False, look_for_keys=False)
src = SCRIPT.replace("__ACTION__", ACTION)
c.exec_command("cat > /tmp/pmic.py << 'PYEOF'\n" + src + "\nPYEOF", timeout=60)
i, o, e = c.exec_command("echo %s | sudo -S -p '' sh -c 'python3 /tmp/pmic.py'" % PW,
                         timeout=90)
print(o.read().decode(errors="replace"))
err = e.read().decode(errors="replace")
if err.strip():
    print("[stderr]", err[:400])
c.close()
