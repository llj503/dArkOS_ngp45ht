"""Aligned evdev recorder + live /proc/interrupts deltas for the joystick keys.

The previous watcher read `os.read(fd, 96)` and then cut 24-byte records out of
whatever arrived, so a short read desynchronised it and every later event was
parsed as garbage -- which is why a confirmed pad movement showed no EV lines.
This one keeps a byte buffer, consumes only whole records, and samples the
GPIO irq counts at the same time, so a single held key distinguishes "pad moved,
irq fired, event reported" from "pad moved but the irq never reached the CPU".

Usage: python keywatch.py [seconds]
"""
import os, sys, paramiko

HOST = os.environ.get("NGP_HOST", "192.168.0.30")
USER = os.environ.get("NGP_USER", "ark")
PW = os.environ.get("NGP_PW", "ark")
SECS = sys.argv[1] if len(sys.argv) > 1 else "150"

SCRIPT = r'''
import os, select, struct, time

DEV = "/dev/input/by-path/platform-play_joystick-event-joystick"
SECS = __SECS__
KEY = {304: "A", 305: "B", 307: "X/NORTH", 308: "Y/WEST", 309: "", 310: "L1/TL",
       311: "R1/TR", 312: "L2/TL2", 313: "R2/TR2", 314: "SELECT", 315: "START",
       316: "MODE", 317: "L3", 318: "R3", 544: "DPAD_UP", 545: "DPAD_DOWN",
       546: "DPAD_LEFT", 547: "DPAD_RIGHT"}

def counts():
    out = {}
    for line in open("/proc/interrupts"):
        if "rk3562-joystick" in line:
            f = line.split()
            hw = f[f.index("rockchip_gpio_irq") + 1]
            out[hw] = sum(int(x) for x in f[1:5])
    return out

fd = os.open(DEV, os.O_RDONLY | os.O_NONBLOCK)
log = open("/tmp/keywatch.log", "w", buffering=1)
prev = counts()
log.write("start dev=%s irq baseline %s\n" % (DEV, sorted(prev.items())))
buf = b""
T0 = time.time()
while time.time() - T0 < SECS:
    select.select([fd], [], [], 0.2)
    try:
        buf += os.read(fd, 4096)
    except BlockingIOError:
        pass
    while len(buf) >= 24:
        rec, buf = buf[:24], buf[24:]
        sec, us, typ, code, val = struct.unpack("qqHHi", rec)
        if typ == 1:
            log.write("%.3f KEY %-9s %d\n" % (time.time() - T0,
                                              KEY.get(code, code), val))
        elif typ == 3:
            log.write("%.3f ABS axis%d %d\n" % (time.time() - T0, code, val))
    cur = counts()
    for hw, v in cur.items():
        if prev.get(hw, -1) != v:
            log.write("%.3f IRQ hwirq %s: %d -> %d\n" %
                      (time.time() - T0, hw, prev.get(hw, -1), v))
    prev = cur
log.write("DONE\n")
os.close(fd)
'''

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PW, timeout=30,
          allow_agent=False, look_for_keys=False)
src = SCRIPT.replace("__SECS__", SECS)
c.exec_command("cat > /tmp/keywatch.py << 'PYEOF'\n" + src + "\nPYEOF", timeout=60)
i, o, e = c.exec_command("echo %s | sudo -S -p '' sh -c '(setsid nohup python3 /tmp/keywatch.py > /tmp/keywatch.err 2>&1 &) ; sleep 3; cat /tmp/keywatch.log /tmp/keywatch.err'" % PW,
                         timeout=120)
print("### started\n" + o.read().decode(errors="replace"))
err = e.read().decode(errors="replace")
if err.strip():
    print("[stderr]", err[:300])
c.close()
