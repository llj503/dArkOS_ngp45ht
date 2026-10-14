"""Watch EV_ABS on the joystick event node while L2/R2 are pressed.

SDL's GameController API resolves left/righttrigger straight from this node's
ABS_Z (code 2) and ABS_RZ (code 5), so if those two move when the GPIO shoulder
switches are pressed, every controller-API consumer (PPSSPP included) now sees
L2/R2.  A heartbeat line is written every 2 s so "the recorder is alive" is a
fact read from the log rather than an assumption.

Usage: python absprobe.py [seconds]
"""
import os, sys, paramiko

HOST = os.environ.get("NGP_HOST", "192.168.0.30")
USER = os.environ.get("NGP_USER", "ark")
PW = os.environ.get("NGP_PW", "ark")
SECS = sys.argv[1] if len(sys.argv) > 1 else "300"

CODE = r'''
import glob, os, struct, time, traceback

DEV = "/dev/input/by-path/platform-play_joystick-event-joystick"
PATH = "/tmp/absprobe.log"
out = open(PATH, "w", buffering=1)
try:
    out.write("start dev=%s size=%d\n" % (DEV, struct.calcsize("qqHHi")))
    fd = os.open(DEV, os.O_RDONLY)
    SZ = struct.calcsize("qqHHi")
    T0 = time.time()
    last_beat = 0
    buf = b""
    out.write("BEGIN\n")
    while time.time() - T0 < __SECS__:
        # read with a short timeout so the heartbeat keeps flowing even when
        # nobody is pressing anything
        r, _, _ = __import__("select").select([fd], [], [], 0.5)
        if time.time() - last_beat > 2:
            out.write("%.1f alive\n" % (time.time() - T0))
            last_beat = time.time()
        if not r:
            continue
        data = os.read(fd, SZ * 16)
        for i in range(0, len(data) - SZ + 1, SZ):
            sec, us, ty, code, val = struct.unpack("qqHHi", data[i:i + SZ])
            if ty == 3:
                out.write("%.3f ABS code%d val=%d\n" % (time.time() - T0, code, val))
            elif ty == 1 and code in (312, 313, 310, 311):
                out.write("%.3f KEY code%d val=%d\n" % (time.time() - T0, code, val))
    out.write("DONE\n")
    os.close(fd)
except Exception:
    out.write("CRASH " + traceback.format_exc())
finally:
    out.close()
'''

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PW, timeout=30,
          allow_agent=False, look_for_keys=False)
c.exec_command("cat > /tmp/absprobe.py << 'PYEOF'\n" + CODE.replace("__SECS__", SECS)
               + "\nPYEOF", timeout=60)
cmd = ("echo %s | sudo -S -p '' sh -c 'rm -f /tmp/absprobe.log; "
       "(setsid nohup python3 -u /tmp/absprobe.py > /tmp/absprobe.out 2>&1 &) ; "
       "sleep 5; head -4 /tmp/absprobe.log; echo ---; tail -3 /tmp/absprobe.out'" % PW)
i, o, e = c.exec_command(cmd, timeout=120)
print(o.read().decode(errors="replace"))
err = e.read().decode(errors="replace")
if err.strip():
    print("[stderr]", err[:300])
c.close()
