import sys, paramiko, os

HOST = os.environ.get("NGP_HOST", "192.168.0.30")
USER = os.environ.get("NGP_USER", "ark")
PW   = os.environ.get("NGP_PW", "ark")

def conn():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PW, timeout=25,
              banner_timeout=25, auth_timeout=25, allow_agent=False, look_for_keys=False)
    return c

def run(cmds, sudo=True):
    c = conn()
    for label, cmd in cmds:
        if sudo and "ark" == USER:
            cmd = "echo %s | sudo -S -p '' sh -c %s" % (repr(PW), _q(cmd))
        i, o, e = c.exec_command(cmd, timeout=120)
        out = o.read().decode(errors="replace"); err = e.read().decode(errors="replace")
        print("\n" + "=" * 68); print("### " + label); print("-" * 68)
        safe = lambda s: sys.stdout.buffer.write((s + "\n").encode("ascii", "replace"))
        if out.strip(): safe(out.rstrip())
        if err.strip(): safe("[stderr] " + err.rstrip())
    c.close()

def _q(s):
    return "'" + s.replace("'", "'\"'\"'") + "'"

if __name__ == "__main__":
    exec(open(sys.argv[1], encoding="utf-8").read())
