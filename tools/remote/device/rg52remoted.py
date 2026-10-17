#!/usr/bin/env python3
"""rg52remoted - remote screen and input for the RG52 Mini (dArkOS).

Runs on the device as root. One TCP control port, line protocol, one command
per line, one reply per line ("OK ..." or "ERR ..."):

  ping                         -> OK pong
  btn <name> [ms]              press and release a pad button (default 80 ms)
  btn+ <name> / btn- <name>    hold / release a pad button
  axis <ABS_X..> <value>       set a pad axis (raw device units)
  key <KEY_..|name> [ms]       press and release a keyboard key (uinput)
  key+ <key> / key- <key>      hold / release a key
  type <text>                  type ASCII text
  mouse <dx> <dy>              move the pointer (uinput, relative)
  click [left|right|middle]    click
  wheel <n>                    scroll
  shot                         -> "OK <w> <h> <len>" then <len> bytes of BGRX
  stream <fps> <kbps>          start H.264 (MPEG-TS) on the stream port, one
                               client; -> OK <port>
  stream stop

Pad buttons are written straight into the real joystick device, so
EmulationStation, emulators and ports see them as real presses with no
configuration. Keyboard and mouse are a separate uinput device, created on
first use.

The picture is ffmpeg kmsgrab: the plane being scanned out, whatever draws it
(ES, games, the console). The stream is encoded by the RK3562's hardware
encoder (h264_rkmpp) straight from the DRM buffer: a few percent of one core.
"""
import argparse, os, socket, subprocess, sys, threading, time

import evdev
from evdev import ecodes as E

PAD_PATH = "/dev/input/by-path/platform-play_joystick-event-joystick"

# physical button -> evdev code (rk3562-joystick: East is A, South is B)
PAD = {
    "a": E.BTN_EAST, "b": E.BTN_SOUTH, "x": E.BTN_NORTH, "y": E.BTN_WEST,
    "l1": E.BTN_TL, "r1": E.BTN_TR, "l2": E.BTN_TL2, "r2": E.BTN_TR2,
    "select": E.BTN_SELECT, "start": E.BTN_START, "mode": E.BTN_MODE,
    "fn": E.BTN_TRIGGER_HAPPY1, "l3": E.BTN_THUMBL, "r3": E.BTN_THUMBR,
    "up": E.BTN_DPAD_UP, "down": E.BTN_DPAD_DOWN,
    "left": E.BTN_DPAD_LEFT, "right": E.BTN_DPAD_RIGHT,
}
# the analog triggers report as axes as well (SDL: lefttrigger a2, righttrigger a5)
TRIGGER_AXIS = {"l2": E.ABS_Z, "r2": E.ABS_RZ}

pad = evdev.InputDevice(PAD_PATH)
pad_lock = threading.Lock()
absinfo = {code: info for code, info in pad.capabilities().get(E.EV_ABS, [])}

ui = None
ui_lock = threading.Lock()


def get_ui():
    global ui
    with ui_lock:
        if ui is None:
            keys = [c for c in E.keys if isinstance(c, int) and 1 <= c <= 248]
            caps = {E.EV_KEY: keys + [E.BTN_LEFT, E.BTN_RIGHT, E.BTN_MIDDLE],
                    E.EV_REL: [E.REL_X, E.REL_Y, E.REL_WHEEL]}
            ui = evdev.UInput(caps, name="rg52remote keyboard+mouse")
            time.sleep(0.3)   # let udev and readers notice the new device
        return ui


def pad_set(name, down):
    code = PAD[name]
    with pad_lock:
        pad.write(E.EV_KEY, code, 1 if down else 0)
        if name in TRIGGER_AXIS and TRIGGER_AXIS[name] in absinfo:
            info = absinfo[TRIGGER_AXIS[name]]
            pad.write(E.EV_ABS, TRIGGER_AXIS[name], info.max if down else info.min)
        pad.write(E.EV_SYN, E.SYN_REPORT, 0)


def keycode(name):
    n = name.upper()
    if not n.startswith("KEY_") and not n.startswith("BTN_"):
        n = "KEY_" + n
    if n not in E.ecodes:
        raise ValueError("unknown key " + name)
    return E.ecodes[n]


SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7',
           '*': '8', '(': '9', ')': '0', '_': 'MINUS', '+': 'EQUAL', '{': 'LEFTBRACE',
           '}': 'RIGHTBRACE', ':': 'SEMICOLON', '"': 'APOSTROPHE', '~': 'GRAVE',
           '|': 'BACKSLASH', '<': 'COMMA', '>': 'DOT', '?': 'SLASH'}
PLAIN = {' ': 'SPACE', '-': 'MINUS', '=': 'EQUAL', '[': 'LEFTBRACE', ']': 'RIGHTBRACE',
         ';': 'SEMICOLON', "'": 'APOSTROPHE', '`': 'GRAVE', '\\': 'BACKSLASH',
         ',': 'COMMA', '.': 'DOT', '/': 'SLASH', '\n': 'ENTER', '\t': 'TAB'}


def type_text(text):
    u = get_ui()
    for ch in text:
        shift = ch.isupper() or ch in SHIFTED
        base = SHIFTED.get(ch) or PLAIN.get(ch) or ch.upper()
        code = keycode(base)
        if shift:
            u.write(E.EV_KEY, E.KEY_LEFTSHIFT, 1)
        u.write(E.EV_KEY, code, 1); u.syn()
        u.write(E.EV_KEY, code, 0)
        if shift:
            u.write(E.EV_KEY, E.KEY_LEFTSHIFT, 0)
        u.syn()
        time.sleep(0.02)


def shot():
    """One frame of the scanned-out plane as raw BGRX."""
    p = subprocess.run(
        ["ffmpeg", "-hide_banner", "-loglevel", "info", "-f", "kmsgrab", "-i", "-",
         "-frames:v", "1", "-vf", "hwdownload,format=bgr0", "-f", "rawvideo", "-"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
    w = h = 0
    for line in p.stderr.decode(errors="replace").splitlines():
        if "Video:" in line and "rawvideo" in line:
            for tok in line.replace(",", " ").split():
                if "x" in tok and tok.split("x")[0].isdigit() and tok.split("x")[1].isdigit():
                    w, h = map(int, tok.split("x"))
                    break
    if not p.stdout or not w:
        raise RuntimeError("kmsgrab failed: " + p.stderr.decode(errors="replace")[-300:])
    return w, h, p.stdout


stream_proc = None
stream_lock = threading.Lock()


def stream_start(port, fps, kbps):
    global stream_proc
    with stream_lock:
        if stream_proc and stream_proc.poll() is None:
            stream_proc.terminate()
            try:
                stream_proc.wait(3)
            except subprocess.TimeoutExpired:
                stream_proc.kill()
        stream_proc = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "kmsgrab",
             "-framerate", str(fps), "-i", "-", "-c:v", "h264_rkmpp",
             "-b:v", "%dk" % kbps, "-g", str(fps), "-flush_packets", "1",
             "-f", "mpegts", "tcp://0.0.0.0:%d?listen=1" % port],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stream_stop():
    global stream_proc
    with stream_lock:
        if stream_proc and stream_proc.poll() is None:
            stream_proc.terminate()
        stream_proc = None


def handle(conn, args):
    f = conn.makefile("rwb", buffering=0)

    def reply(s):
        f.write((s + "\n").encode())

    for raw in f:
        line = raw.decode(errors="replace").strip()
        if not line:
            continue
        parts = line.split(" ", 1)
        cmd, rest = parts[0].lower(), (parts[1] if len(parts) > 1 else "")
        a = rest.split()
        try:
            if cmd == "ping":
                reply("OK pong")
            elif cmd == "btn":
                pad_set(a[0].lower(), True)
                time.sleep((int(a[1]) if len(a) > 1 else 80) / 1000)
                pad_set(a[0].lower(), False)
                reply("OK")
            elif cmd in ("btn+", "btn-"):
                pad_set(a[0].lower(), cmd == "btn+")
                reply("OK")
            elif cmd == "axis":
                with pad_lock:
                    pad.write(E.EV_ABS, E.ecodes[a[0].upper()], int(a[1]))
                    pad.write(E.EV_SYN, E.SYN_REPORT, 0)
                reply("OK")
            elif cmd == "key":
                u = get_ui(); c = keycode(a[0])
                u.write(E.EV_KEY, c, 1); u.syn()
                time.sleep((int(a[1]) if len(a) > 1 else 60) / 1000)
                u.write(E.EV_KEY, c, 0); u.syn()
                reply("OK")
            elif cmd in ("key+", "key-"):
                u = get_ui(); u.write(E.EV_KEY, keycode(a[0]), 1 if cmd == "key+" else 0); u.syn()
                reply("OK")
            elif cmd == "type":
                type_text(rest); reply("OK")
            elif cmd == "mouse":
                u = get_ui()
                u.write(E.EV_REL, E.REL_X, int(a[0])); u.write(E.EV_REL, E.REL_Y, int(a[1])); u.syn()
                reply("OK")
            elif cmd == "click":
                u = get_ui()
                b = {"left": E.BTN_LEFT, "right": E.BTN_RIGHT, "middle": E.BTN_MIDDLE}[(a[0] if a else "left").lower()]
                u.write(E.EV_KEY, b, 1); u.syn(); time.sleep(0.05)
                u.write(E.EV_KEY, b, 0); u.syn()
                reply("OK")
            elif cmd == "wheel":
                u = get_ui(); u.write(E.EV_REL, E.REL_WHEEL, int(a[0])); u.syn(); reply("OK")
            elif cmd == "shot":
                w, h, data = shot()
                f.write(("OK %d %d %d\n" % (w, h, len(data))).encode())
                f.write(data)
            elif cmd == "stream":
                if a and a[0] == "stop":
                    stream_stop(); reply("OK")
                else:
                    fps = int(a[0]) if a else 15
                    kbps = int(a[1]) if len(a) > 1 else 2500
                    stream_start(args.stream_port, fps, kbps)
                    reply("OK %d" % args.stream_port)
            elif cmd == "quit":
                reply("OK bye"); break
            else:
                reply("ERR unknown command " + cmd)
        except Exception as e:  # keep the connection alive on a bad command
            reply("ERR %s: %s" % (type(e).__name__, e))
    conn.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=5555)
    ap.add_argument("--stream-port", type=int, default=5556)
    args = ap.parse_args()
    if os.geteuid() != 0:
        sys.exit("rg52remoted needs root (pad writes, uinput, kmsgrab)")
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((args.bind, args.port))
    s.listen(4)
    print("rg52remoted on %s:%d, stream port %d" % (args.bind, args.port, args.stream_port), flush=True)
    while True:
        conn, _ = s.accept()
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=handle, args=(conn, args), daemon=True).start()


if __name__ == "__main__":
    main()
