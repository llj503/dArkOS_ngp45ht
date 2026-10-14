"""dArkOS-side key diagnostics: who owns the 7 dead pins, and do they move?

Collects, in one SSH session and with no user action required:
  1. kernel/model/uptime
  2. /sys/class/gpio exports + debugfs gpio owners (a userspace script that
     exported one of these pins as output would drive the pad dead)
  3. debugfs pinmux-pins for the 7 dead pins and 2 working references
     (global pin numbers: gpio0 base 0, gpio1 32, gpio2 64, gpio3 96)
  4. GPIO bank regs (ddr tells whether the SoC is *driving* the pad)
  5. dmesg noise about gpio/pinctrl/irq
  6. /proc/interrupts for the gpio banks

Usage: NGP_USER=ark NGP_PW=ark python keydiag.py
"""
import os, sys, paramiko

HOST = os.environ.get("NGP_HOST", "192.168.0.30")
USER = os.environ.get("NGP_USER", "ark")
PW = os.environ.get("NGP_PW", "ark")

PINS = {55: "g1_C7 MODE", 57: "g1_D1 L1", 58: "g1_D2 L2", 59: "g1_D3 R1",
        60: "g1_D4 R2", 64: "g2_A0 X", 65: "g2_A1 Y",
        21: "g0_C5 (works)", 102: "g3_A6 (works)"}

CMDS = [
    ("env", "uname -r; tr -d '\\0' < /proc/device-tree/model; uptime; "
            "mount -t debugfs none /sys/kernel/debug 2>/dev/null; "
            "ls /sys/kernel/debug/ | head -20"),
    ("userspace gpio exports", "ls /sys/class/gpio/ 2>&1; "
     "for d in /sys/class/gpio/gpio*; do [ -d $d ] && "
     "echo \"$(basename $d) dir=$(cat $d/direction 2>/dev/null) "
     "val=$(cat $d/value 2>/dev/null) label=$(cat $d/label 2>/dev/null)\"; done"),
    ("debugfs gpio owners", "cat /sys/kernel/debug/gpio 2>&1 | head -80"),
    ("pinmux ownership", "for f in /sys/kernel/debug/pinctrl/*/pinmux-pins; do "
     "echo \"-- $f\"; grep -E '^pin \"?(55|57|58|59|60|64|65|21|102)\\b' $f; done"),
    ("dmesg gpio/pinctrl", "dmesg 2>/dev/null | grep -iE 'gpio|pinctrl|pinmux|irq|"
     "play_joystick|joystick' | tail -40"),
    ("gpio interrupts", "grep -i gpio /proc/interrupts; "
     "cat /proc/interrupts | head -3"),
    ("joystick event node", "ls -l /dev/input/by-path/ 2>&1; "
     "grep -E '^(N:|P:)' /proc/bus/input/devices | head -30"),
]

BANKREG = r'''
import mmap, os, struct
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
def rd(a):
    m = mmap.mmap(fd, 0x1000, mmap.MAP_SHARED, mmap.PROT_READ, offset=a & ~0xFFF)
    v = struct.unpack("<I", m[(a & 0xFFF):(a & 0xFFF) + 4])[0]
    m.close()
    return v
BASE = {0: 0xff260000, 1: 0xff620000, 2: 0xff630000, 3: 0xffac0000}
WATCH = {1: (23, 24, 25, 26, 27, 28), 2: (0, 1), 0: (21,), 3: (6,)}
REGS = (("dr", 0x00), ("ddr", 0x08), ("int_en", 0x10), ("int_mask", 0x18),
        ("ext_port", 0x70))
for b in sorted(BASE):
    v = dict((n, rd(BASE[b] + o)) for n, o in REGS)
    print("bank%d " % b + " ".join("%s=%08x" % i for i in v.items()))
    for p in WATCH[b]:
        print("   g%d_%s%d  ddr=%d dr=%d ext=%d int_en=%d int_mask=%d" %
              (b, "ABCD"[p // 8], p % 8, (v["ddr"] >> p) & 1, (v["dr"] >> p) & 1,
               (v["ext_port"] >> p) & 1, (v["int_en"] >> p) & 1,
               (v["int_mask"] >> p) & 1))
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

    for label, cmd in CMDS:
        out, err = sh(cmd)
        print("\n" + "=" * 70 + "\n### " + label + "\n" + "-" * 70)
        sys.stdout.buffer.write(((out.rstrip() + "\n") if out.strip() else "(empty)\n")
                                .encode("ascii", "replace"))
        if err.strip():
            print("[stderr]", err.strip()[:400])

    c.exec_command("cat > /tmp/bankreg.py << 'PYEOF'\n" + BANKREG + "\nPYEOF",
                   timeout=60)
    out, err = sh("python3 /tmp/bankreg.py")
    print("\n" + "=" * 70 + "\n### per-pin bank bits\n" + "-" * 70)
    sys.stdout.buffer.write(out.encode("ascii", "replace"))
    if err.strip():
        print("[stderr]", err[:400])
    c.close()


main()
