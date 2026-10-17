#!/usr/bin/env python3
"""rg52remote - see and drive an RG52 Mini running dArkOS from this PC.

  rg52remote.py setup            install this tool's ssh key on the device (once per card)
  rg52remote.py start | stop     upload and start / stop the daemon on the device
  rg52remote.py status           is the daemon answering
  rg52remote.py shot [file]      screenshot, landscape PNG (default run\\shot.png); prints the path
  rg52remote.py btn <b> [ms]     pad button: a b x y l1 r1 l2 r2 select start mode fn l3 r3 up down left right
  rg52remote.py hold|release <b> hold / release a pad button
  rg52remote.py key <key> [ms]   keyboard key (KEY_ENTER, enter, a, f1 ...)
  rg52remote.py type <text>      type text
  rg52remote.py mouse <dx> <dy> | click [left|right|middle] | wheel <n>
  rg52remote.py send <raw cmd>   any daemon command (see device/rg52remoted.py)
  rg52remote.py view [--zoom 0.5 | --scale W] [--fps N] [--kbps N]
                                 live window with keyboard/mouse control; resize the window
                                 and the picture follows it

Device address: --host, or RG52_HOST, default rg52mini.home.local / 192.168.1.104.
No third-party Python modules; needs ffmpeg and OpenSSH (ssh, scp) in PATH. Windows or Linux.
"""
import argparse, os, socket, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
RUN = os.path.join(HERE, "run")
KEY = os.path.join(HERE, "id_rg52")
DAEMON = os.path.join(HERE, "device", "rg52remoted.py")
PORT, STREAM_PORT = 5555, 5556
USER, PASSWORD = "ark", "ark"


def host_default():
    return os.environ.get("RG52_HOST", "192.168.1.104")


# ---------------------------------------------------------------- ssh helpers
def ssh_base(host):
    return ["ssh", "-i", KEY, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=" + os.devnull,
            "-o", "LogLevel=ERROR", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "%s@%s" % (USER, host)]


def ssh(host, command, check=True):
    p = subprocess.run(ssh_base(host) + [command], capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.exit("ssh failed (%d): %s\nIf the key is not installed on this card yet: rg52remote.py setup"
                 % (p.returncode, (p.stderr or p.stdout).strip()))
    return p.stdout


def setup(host):
    """Put this tool's public key into ~ark/.ssh/authorized_keys.

    ssh cannot be handed a password, so the one password login goes through
    sshpass: WSL's on Windows, the system one elsewhere (apt install sshpass)."""
    if not os.path.exists(KEY):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "rg52remote", "-f", KEY], check=True)
    pub = open(KEY + ".pub").read().strip()
    cmd = ("mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && "
           "grep -qF '%s' ~/.ssh/authorized_keys || echo '%s' >> ~/.ssh/authorized_keys; "
           "chmod 600 ~/.ssh/authorized_keys; echo key-ok") % (pub, pub)
    sshpass = (["wsl", "-e"] if os.name == "nt" else []) + ["sshpass"]
    p = subprocess.run(sshpass + ["-p", PASSWORD, "ssh", "-o", "StrictHostKeyChecking=no",
                        "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "%s@%s" % (USER, host), cmd],
                       capture_output=True, text=True)
    if "key-ok" not in p.stdout:
        sys.exit("setup failed: %s %s\nIs 'Enable Remote Services' on? Is sshpass installed in WSL?"
                 % (p.stdout, p.stderr))
    print("key installed on %s" % host)


def start(host):
    if subprocess.run(["scp", "-i", KEY, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=" + os.devnull,
                       "-o", "LogLevel=ERROR", "-o", "BatchMode=yes", DAEMON,
                       "%s@%s:/tmp/rg52remoted.py" % (USER, host)]).returncode != 0:
        sys.exit("upload failed; run: rg52remote.py setup")
    ssh(host, "sudo pkill -f '^python3 /tmp/rg52remoted.py' ; "
              "sudo setsid python3 /tmp/rg52remoted.py > /tmp/rg52remoted.log 2>&1 < /dev/null & sleep 1.5; "
              "cat /tmp/rg52remoted.log", check=False)
    for _ in range(10):
        try:
            if Remote(host).cmd("ping").startswith("OK"):
                print("daemon running on %s:%d" % (host, PORT)); return
        except OSError:
            time.sleep(0.5)
    sys.exit("daemon did not answer; see /tmp/rg52remoted.log on the device")


def stop(host):
    ssh(host, "sudo pkill -f '^python3 /tmp/rg52remoted.py'; sudo pkill -f 'kmsgrab.*h264_rkmpp'", check=False)
    print("stopped")


# ------------------------------------------------------------ daemon client
class Remote:
    def __init__(self, host):
        self.s = socket.create_connection((host, PORT), timeout=10)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.f = self.s.makefile("rwb", buffering=0)
        self.lock = threading.Lock()

    def cmd(self, line):
        with self.lock:
            self.f.write((line + "\n").encode())
            return self.f.readline().decode(errors="replace").strip()

    def shot_raw(self):
        with self.lock:
            self.f.write(b"shot\n")
            head = self.f.readline().decode().split()
            if head[0] != "OK":
                raise RuntimeError(" ".join(head))
            w, h, n = map(int, head[1:4])
            buf = bytearray()
            while len(buf) < n:
                chunk = self.f.read(n - len(buf))
                if not chunk:
                    raise RuntimeError("connection closed")
                buf += chunk
            return w, h, bytes(buf)


def shot(host, out):
    w, h, data = Remote(host).shot_raw()
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    # the panel is portrait 720x1280 and scanned out that way; turn it to landscape
    vf = "transpose=2" if h > w else "null"
    p = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr0",
                        "-s", "%dx%d" % (w, h), "-i", "-", "-vf", vf, "-update", "1", out], input=data)
    if p.returncode != 0:
        sys.exit("ffmpeg conversion failed")
    print(os.path.abspath(out))


# --------------------------------------------------------------------- viewer
# PC key -> pad button (keysym names as tkinter reports them)
PAD_KEYS = {"Up": "up", "Down": "down", "Left": "left", "Right": "right",
            "x": "a", "z": "b", "s": "x", "a": "y",
            "q": "l1", "w": "r1", "1": "l2", "2": "r2",
            "Return": "start", "BackSpace": "select", "Shift_R": "select",
            "Tab": "mode", "f": "fn", "e": "l3", "r": "r3"}
HELP = ("pad: arrows, X=A Z=B S=X A=Y, Q/W=L1/R1, 1/2=L2/R2, Enter=Start, Backspace=Select, "
        "Tab=Mode, F=Fn | F12: keyboard mode (keys go to the device as a keyboard) | "
        "mouse: drag with left button = pointer, right click = right button | F5: screenshot")

TK_TO_EV = {"Return": "ENTER", "BackSpace": "BACKSPACE", "Escape": "ESC", "Tab": "TAB", "space": "SPACE",
            "Up": "UP", "Down": "DOWN", "Left": "LEFT", "Right": "RIGHT", "Shift_L": "LEFTSHIFT",
            "Shift_R": "RIGHTSHIFT", "Control_L": "LEFTCTRL", "Control_R": "RIGHTCTRL",
            "Alt_L": "LEFTALT", "Alt_R": "RIGHTALT", "Delete": "DELETE", "Home": "HOME", "End": "END",
            "Prior": "PAGEUP", "Next": "PAGEDOWN", "minus": "MINUS", "equal": "EQUAL", "period": "DOT",
            "comma": "COMMA", "slash": "SLASH", "semicolon": "SEMICOLON", "apostrophe": "APOSTROPHE",
            "bracketleft": "LEFTBRACE", "bracketright": "RIGHTBRACE", "backslash": "BACKSLASH",
            "grave": "GRAVE"}


KEYS_HELP = """\
RG52 Mini remote view - %s
  Pad (default mode)          Device
    Arrows                      D-pad
    X / Z / S / A               A / B / X / Y
    Q / W                       L1 / R1
    1 / 2                       L2 / R2
    Enter / Backspace           Start / Select
    Tab / F                     Mode / Fn
    E / R                       L3 / R3
  F12                         toggle keyboard mode (PC keys go to the device as a keyboard)
  F5                          screenshot to run\\shot-<time>.png
  Mouse: drag with left button = move pointer, double click = left click,
         right click = right click, wheel = scroll
  Resize the window and the picture follows it (the stream reconnects, ~1 s).
  Close the window to stop the stream.
"""


def view(host, fps, kbps, width):
    import tkinter as tk
    print(KEYS_HELP % host, flush=True)
    rem = Remote(host)
    root = tk.Tk()
    root.title("RG52 Mini - %s" % host)
    root.configure(bg="black")
    # the picture area grows with the window; the image is fitted into it, 16:9
    area = tk.Frame(root, bg="black", width=width, height=width * 9 // 16)
    area.pack(fill="both", expand=True)
    area.pack_propagate(False)
    lbl = tk.Label(area, bd=0, bg="black"); lbl.place(relx=0.5, rely=0.5, anchor="center")
    status = tk.Label(root, text=HELP, anchor="w", justify="left", wraplength=width, font=("Segoe UI", 8))
    status.pack(fill="x")
    state = {"frame": None, "kbd": False, "held": set(), "last": None, "alive": True,
             "ff": None, "gen": 0, "size": None, "pending": None}

    def start_pipeline(w):
        """(Re)start the stream on the device and the decoder here at width w.

        The device side serves one client per start, so a new size means a new
        stream; the encoder is unchanged, the scaling is done by ffmpeg on the PC."""
        w = max(160, w - w % 2)
        h = (w * 9 // 16) // 2 * 2
        state["size"] = (w, h)
        state["gen"] += 1
        gen = state["gen"]
        if state["ff"]:
            state["ff"].kill()
        r = rem.cmd("stream %d %d" % (fps, kbps))
        if not r.startswith("OK"):
            root.after(0, lambda: status.configure(text="stream: " + r)); return
        time.sleep(0.8)
        ff = subprocess.Popen(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-fflags", "nobuffer", "-flags", "low_delay",
             "-probesize", "32768", "-analyzeduration", "0", "-i", "tcp://%s:%d" % (host, STREAM_PORT),
             "-vf", "transpose=2,scale=%d:%d" % (w, h), "-f", "image2pipe", "-c:v", "ppm", "-"],
            stdout=subprocess.PIPE, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        state["ff"] = ff

        def reader():
            rd = ff.stdout
            while state["alive"] and state["gen"] == gen:
                magic = rd.readline()
                if not magic:
                    break
                dims = rd.readline(); maxv = rd.readline()
                fw, fh = map(int, dims.split())
                data = rd.read(fw * fh * 3)
                if state["gen"] == gen:
                    state["frame"] = magic + dims + maxv + data
            if state["gen"] == gen:
                state["alive"] = False
        threading.Thread(target=reader, daemon=True).start()

    def fit_width():
        aw, ah = area.winfo_width(), area.winfo_height()
        return min(aw, ah * 16 // 9)

    def on_resize(_e=None):
        if state["pending"]:
            root.after_cancel(state["pending"])

        def apply():
            state["pending"] = None
            w = fit_width()
            if state["size"] and abs(w - state["size"][0]) < 16:
                return
            status.configure(wraplength=max(200, area.winfo_width()))
            threading.Thread(target=start_pipeline, args=(w,), daemon=True).start()
        state["pending"] = root.after(500, apply)
    area.bind("<Configure>", on_resize)

    def tick():
        fr = state["frame"]
        if fr is not None:
            state["frame"] = None
            img = tk.PhotoImage(data=fr, format="PPM")
            lbl.configure(image=img); lbl.image = img
        if state["alive"]:
            root.after(15, tick)
        else:
            status.configure(text="stream ended")
    threading.Thread(target=start_pipeline, args=(width,), daemon=True).start()
    root.after(50, tick)

    def send(line):
        threading.Thread(target=lambda: rem.cmd(line), daemon=True).start()

    def keydown(e):
        if e.keysym == "F12":
            state["kbd"] = not state["kbd"]
            root.title("RG52 Mini - %s - %s" % (host, "KEYBOARD mode" if state["kbd"] else "pad mode"))
            return
        if e.keysym == "F5":
            path = os.path.join(RUN, time.strftime("shot-%Y%m%d-%H%M%S.png"))
            threading.Thread(target=lambda: shot(host, path), daemon=True).start(); return
        if e.keysym in state["held"]:
            return                      # key repeat
        state["held"].add(e.keysym)
        if state["kbd"]:
            k = TK_TO_EV.get(e.keysym, e.keysym if len(e.keysym) == 1 else e.keysym.upper())
            send("key+ %s" % k)
        elif e.keysym in PAD_KEYS:
            send("btn+ %s" % PAD_KEYS[e.keysym])

    def keyup(e):
        state["held"].discard(e.keysym)
        if state["kbd"]:
            k = TK_TO_EV.get(e.keysym, e.keysym if len(e.keysym) == 1 else e.keysym.upper())
            send("key- %s" % k)
        elif e.keysym in PAD_KEYS:
            send("btn- %s" % PAD_KEYS[e.keysym])

    def drag(e):
        if state["last"]:
            dx, dy = e.x - state["last"][0], e.y - state["last"][1]
            if dx or dy:
                send("mouse %d %d" % (dx, dy))
        state["last"] = (e.x, e.y)

    lbl.bind("<ButtonPress-1>", lambda e: state.update(last=(e.x, e.y)))
    lbl.bind("<B1-Motion>", drag)
    lbl.bind("<Double-Button-1>", lambda e: send("click left"))
    lbl.bind("<Button-3>", lambda e: send("click right"))
    lbl.bind("<MouseWheel>", lambda e: send("wheel %d" % (1 if e.delta > 0 else -1)))
    root.bind("<KeyPress>", keydown)
    root.bind("<KeyRelease>", keyup)

    def close():
        state["alive"] = False
        if state["ff"]:
            state["ff"].kill()
        try:
            rem.cmd("stream stop")
        except OSError:
            pass
        root.destroy()
    root.protocol("WM_DELETE_WINDOW", close)
    root.mainloop()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=host_default())
    ap.add_argument("cmd")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--fps", type=int, default=15)
    ap.add_argument("--kbps", type=int, default=2500)
    ap.add_argument("--scale", type=int, default=None, help="viewer start width in pixels")
    ap.add_argument("--zoom", type=float, default=0.75,
                    help="viewer start size as a fraction of 1280x720 (0.5 = 640x360); the window "
                         "can then be resized and the picture follows it")
    o = ap.parse_args()
    if o.scale is None:
        o.scale = int(1280 * o.zoom)
    c, a, h = o.cmd, o.args, o.host
    if c == "setup":
        setup(h)
    elif c == "start":
        start(h)
    elif c == "stop":
        stop(h)
    elif c == "status":
        try:
            print(Remote(h).cmd("ping"))
        except OSError as e:
            sys.exit("not running: %s" % e)
    elif c == "shot":
        shot(h, a[0] if a else os.path.join(RUN, "shot.png"))
    elif c == "btn":
        print(Remote(h).cmd("btn " + " ".join(a)))
    elif c in ("hold", "release"):
        print(Remote(h).cmd(("btn+ " if c == "hold" else "btn- ") + a[0]))
    elif c in ("key", "type", "mouse", "click", "wheel"):
        print(Remote(h).cmd(c + " " + " ".join(a)))
    elif c == "send":
        print(Remote(h).cmd(" ".join(a)))
    elif c == "view":
        view(h, o.fps, o.kbps, o.scale)
    else:
        ap.print_help(); sys.exit(2)


if __name__ == "__main__":
    main()
