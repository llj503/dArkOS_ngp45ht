#!/usr/bin/env python3
"""ngpremote - see and drive the NGP45HT (dArkOS) from this PC over SSH.

  python ngpremote.py setup            install this tool's ssh key on the device (once per card)
  python ngpremote.py start | stop     upload + start / stop the daemon on the device
  python ngpremote.py status           is the daemon answering
  python ngpremote.py shot [file]      one screenshot (default run/shot.png), prints the path
  python ngpremote.py btn <b> [ms]     pad button: a b x y l1 r1 l2 r2 select start mode l3 r3
                                       up down left right
  python ngpremote.py hold|release <b> hold / release a pad button
  python ngpremote.py key <key> [ms]   keyboard key (KEY_ENTER, enter, f1 ...)
  python ngpremote.py type <text>      type ASCII text
  python ngpremote.py mouse <dx> <dy> | click [left|right|middle] | wheel <n>
  python ngpremote.py send <cmd>       any daemon command
  python ngpremote.py view [--fps N]   live window with pad/keyboard control

Device address: --host or NGP_HOST, default 192.168.0.30.  The panel scans out
1024x768 landscape natively, so nothing here rotates anything.

Needs only the standard library plus Pillow on the PC (no ffmpeg); on the device
it needs ffmpeg (kmsgrab), python3-evdev and root.  dArkOS opens port 22 only
after Settings -> Options -> Enable Remote Services, and that does not survive a
reboot, so expect to turn it on after every power cycle.
"""
import argparse, base64, os, socket, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
RUN = os.path.join(HERE, "run")
KEY = os.path.join(HERE, "id_ngp")
DAEMON = os.path.join(HERE, "remote_dev.py")
REMOTE_DAEMON = "/tmp/ngpremoted.py"
PORT = 5555
USER, PASSWORD = "ark", "ark"


def host_default():
    return os.environ.get("NGP_HOST", "192.168.0.30")


# ---------------------------------------------------------------- ssh helpers
def ssh_base(host):
    return ["ssh", "-i", KEY, "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=" + os.devnull, "-o", "LogLevel=ERROR",
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "%s@%s" % (USER, host)]


def ssh(host, command, check=True):
    p = subprocess.run(ssh_base(host) + [command], capture_output=True, text=True)
    if check and p.returncode != 0:
        sys.exit("ssh failed (%d): %s\nIf this card has no key yet: ngpremote.py setup\n"
                 "Is Settings -> Options -> Enable Remote Services on?"
                 % (p.returncode, (p.stderr or p.stdout).strip()))
    return p.stdout


def rootsh(cmd):
    """Run cmd as root on the device.

    ark needs a password for sudo and nested quoting through ssh is what broke
    the first version of this, so the inner command travels base64-encoded."""
    b = base64.b64encode(cmd.encode()).decode()
    return "echo %s | sudo -S -p '' sh -c 'echo %s | base64 -d | bash'" % (PASSWORD, b)


def setup(host):
    """Put this tool's public key into ~ark/.ssh/authorized_keys.

    ssh cannot be handed a password, so the single password login goes through
    sshpass: WSL's on Windows, the system one elsewhere (apt install sshpass)."""
    if not os.path.exists(KEY):
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "ngpremote",
                        "-f", KEY], check=True)
    pub = open(KEY + ".pub").read().strip()
    cmd = ("mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && "
           "grep -qF '%s' ~/.ssh/authorized_keys || echo '%s' >> ~/.ssh/authorized_keys; "
           "chmod 600 ~/.ssh/authorized_keys; echo key-ok") % (pub, pub)
    sshpass = (["wsl", "-e"] if os.name == "nt" else []) + ["sshpass"]
    p = subprocess.run(sshpass + ["-p", PASSWORD, "ssh", "-o", "StrictHostKeyChecking=no",
                                  "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
                                  "%s@%s" % (USER, host), cmd], capture_output=True, text=True)
    if "key-ok" not in p.stdout:
        sys.exit("setup failed: %s %s\nIs 'Enable Remote Services' on? Is sshpass installed in WSL?"
                 % (p.stdout, p.stderr))
    print("key installed on %s" % host)


def start(host):
    rc = subprocess.run(["scp", "-i", KEY, "-o", "StrictHostKeyChecking=no",
                         "-o", "UserKnownHostsFile=" + os.devnull, "-o", "LogLevel=ERROR",
                         "-o", "BatchMode=yes", DAEMON,
                         "%s@%s:%s" % (USER, host, REMOTE_DAEMON)]).returncode
    if rc != 0:
        sys.exit("upload failed; run: ngpremote.py setup")
    ssh(host, rootsh("pkill -f %s ; sleep 0.5; setsid python3 %s > /tmp/ngpremoted.log 2>&1 "
                     "< /dev/null & sleep 1.5; cat /tmp/ngpremoted.log"
                     % (REMOTE_DAEMON, REMOTE_DAEMON)), check=False)
    for _ in range(10):
        try:
            if Remote(host).cmd("ping").startswith("OK"):
                print("daemon running on %s:%d" % (host, PORT))
                return
        except OSError:
            time.sleep(0.5)
    sys.exit("daemon did not answer; see /tmp/ngpremoted.log on the device")


def stop(host):
    ssh(host, rootsh("pkill -f %s ; pkill -f kmsgrab; true" % REMOTE_DAEMON), check=False)
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


def grab(w, h, data):
    """Raw BGRX off the device -> PIL image; rotated only if the panel is portrait."""
    from PIL import Image
    img = Image.frombytes("RGBX", (w, h), data, "raw", "BGRX")
    if h > w:
        img = img.transpose(Image.Transpose.ROTATE_90)
    return img.convert("RGB")


def shot(host, out):
    w, h, data = Remote(host).shot_raw()
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    grab(w, h, data).save(out)
    print("%s (%dx%d)" % (os.path.abspath(out), w, h))


# --------------------------------------------------------------------- viewer
PAD_KEYS = {"Up": "up", "Down": "down", "Left": "left", "Right": "right",
            "x": "a", "z": "b", "s": "x", "a": "y",
            "q": "l1", "w": "r1", "1": "l2", "2": "r2",
            "Return": "start", "BackSpace": "select", "Shift_R": "select",
            "Tab": "mode", "e": "l3", "r": "r3"}
HELP = ("pad: arrows, X=A Z=B S=X A=Y, Q/W=L1/R1, 1/2=L2/R2, Enter=Start, "
        "Backspace=Select, Tab=Mode | F12 keyboard mode | F5 saves a screenshot")

TK_TO_EV = {"Return": "ENTER", "BackSpace": "BACKSPACE", "Escape": "ESC", "Tab": "TAB",
            "space": "SPACE", "Up": "UP", "Down": "DOWN", "Left": "LEFT", "Right": "RIGHT",
            "Shift_L": "LEFTSHIFT", "Shift_R": "RIGHTSHIFT", "Control_L": "LEFTCTRL",
            "Control_R": "RIGHTCTRL", "Alt_L": "LEFTALT", "Alt_R": "RIGHTALT",
            "Delete": "DELETE", "Home": "HOME", "End": "END", "Prior": "PAGEUP",
            "Next": "PAGEDOWN", "minus": "MINUS", "equal": "EQUAL", "period": "DOT",
            "comma": "COMMA", "slash": "SLASH", "semicolon": "SEMICOLON",
            "apostrophe": "APOSTROPHE", "bracketleft": "LEFTBRACE",
            "bracketright": "RIGHTBRACE", "backslash": "BACKSLASH", "grave": "GRAVE"}

KEYS_HELP = """\
NGP45HT remote view - %s
  Arrows D-pad | X/Z/S/A = A/B/X/Y | Q/W = L1/R1 | 1/2 = L2/R2
  Enter Start, Backspace Select, Tab Mode, E/R = L3/R3
  F12 keyboard mode, F5 screenshot
"""


def view(host, fps, width):
    import tkinter as tk
    from PIL import ImageTk
    print(KEYS_HELP % host, flush=True)
    rem = Remote(host)
    root = tk.Tk()
    root.title("NGP45HT - %s" % host)
    root.configure(bg="black")
    lbl = tk.Label(root, bd=0, bg="black")
    lbl.pack(fill="both", expand=True)
    status = tk.Label(root, text=HELP, anchor="w", justify="left",
                      wraplength=width, font=("Segoe UI", 8))
    status.pack(fill="x")
    state = {"kbd": False, "held": set(), "alive": True, "size": (width * 4 // 3, width)}

    def fit():
        aw, ah = max(320, lbl.winfo_width()), max(240, lbl.winfo_height())
        state["size"] = (max(160, min(aw, ah * 4 // 3)), max(120, min(ah, aw * 3 // 4)))

    def tick():
        if not state["alive"]:
            return
        try:
            w, h, data = rem.shot_raw()
            img = grab(w, h, data).resize(state["size"])
            lbl.configure(image=ImageTk.PhotoImage(img))
            status.configure(text="%dx%d panel -> %dx%d window | %s"
                             % (w, h, state["size"][0], state["size"][1], HELP))
        except (OSError, RuntimeError) as e:
            status.configure(text="grab failed: %s" % e)
            return
        root.after(int(1000 / max(1, fps)), tick)

    def send(line):
        threading.Thread(target=lambda: rem.cmd(line), daemon=True).start()

    def keydown(e):
        if e.keysym == "F12":
            state["kbd"] = not state["kbd"]
            root.title("NGP45HT - %s - %s"
                       % (host, "KEYBOARD mode" if state["kbd"] else "pad mode"))
            return
        if e.keysym == "F5":
            path = os.path.join(RUN, time.strftime("shot-%Y%m%d-%H%M%S.png"))
            threading.Thread(target=lambda: shot(host, path), daemon=True).start()
            return
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

    lbl.bind("<ButtonPress-1>", lambda e: send("click left"))
    lbl.bind("<Button-3>", lambda e: send("click right"))
    root.bind("<KeyPress>", keydown)
    root.bind("<KeyRelease>", keyup)
    root.bind("<Configure>", lambda e: fit())

    def close():
        state["alive"] = False
        root.destroy()
    root.protocol("WM_DELETE_WINDOW", close)
    root.geometry("%dx%d+80+40" % state["size"])
    fit()
    root.after(120, tick)
    root.mainloop()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default=host_default())
    ap.add_argument("cmd")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--fps", type=int, default=3,
                    help="viewer frame rate; each frame costs one kmsgrab on the device")
    ap.add_argument("--scale", type=int, default=576, help="viewer start height in pixels")
    o = ap.parse_args()
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
        view(h, o.fps, o.scale)
    else:
        ap.print_help(); sys.exit(2)


if __name__ == "__main__":
    main()
