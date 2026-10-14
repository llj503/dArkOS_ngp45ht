"""Correlate the stock (working) evdev key stream with the stock GPIO register
samples, so the pin->button table is proven rather than inherited.

gpio_ee.log lines: "<epoch> <bank0> <bank1> <bank2> <bank3>" every ~0.23 s,
values from `busybox devmem` of each bank's EXT_PORT (offset 0x70).
ee_event3.bin is a raw /dev/input/event3 capture (struct input_event = qqHHi).
Both timestamps come from the device clock, so they are directly comparable.
"""
import struct, sys, bisect

CODE = {304: "A/SOUTH", 305: "B/EAST", 307: "X/NORTH", 308: "Y/WEST",
        310: "L1/TL", 311: "R1/TR", 312: "L2/TL2", 313: "R2/TR2",
        314: "SELECT", 315: "START", 316: "MODE", 317: "L3", 318: "R3",
        544: "DPAD_UP", 545: "DPAD_DOWN", 546: "DPAD_LEFT", 547: "DPAD_RIGHT"}
BANK = {0: "gpio0", 1: "gpio1", 2: "gpio2", 3: "gpio3"}

samples = []
events = []
for line in open("gpio_ee.log"):
    p = line.split()
    if len(p) != 5:
        continue
    t = float(p[0])
    v = [int(x, 16) for x in p[1:]]
    if samples:
        pt, pv = samples[-1]
        for b in range(4):
            d = v[b] ^ pv[b]
            if d:
                for pin in range(32):
                    if (d >> pin) & 1:
                        events.append((t, b, pin, (v[b] >> pin) & 1))
    samples.append((t, v))

for t, b, pin, lvl in events:
    print("%10.3f  %s pin %2d (%s%d) -> %d" %
          (t - samples[0][0], BANK[b], pin, "ABCD"[pin // 8], pin % 8, lvl))

ts = [s[0] for s in samples]
raw = open(sys.argv[1] if len(sys.argv) > 1 else "ee_event3.bin", "rb").read()
n = len(raw) // 24
print("\n=== %d evdev records, %d register samples ===" % (n, len(samples)))
t0 = samples[0][0]
for i in range(n):
    sec, usec, typ, code, val = struct.unpack_from("qqHHi", raw, i * 24)
    if typ != 1 or code not in CODE:
        continue
    t = sec + usec / 1e6
    if val != 1:
        continue
    near = [e for e in events if t - 0.7 <= e[0] <= t + 0.7]
    print("press %-11s at %8.3f -> %s" %
          (CODE[code], t - t0,
           ", ".join("%s pin%d->%d" % (BANK[b], pin, lvl) for _, b, pin, lvl in near)
           or "no register change in window"))
