"""Upload a local shell script to the NGP45HT card and run it there.

  python devsh.py ngp-core-update.sh plan
  python devsh.py other.sh --32 check mame

The script lands in /home/ark (ark-writable, so nothing needs sudo) and CRLF is
stripped on the way, which is what breaks every Windows-written .sh under bash.
"""
import io
import os
import sys

import paramiko

HOST = os.environ.get("NGP_HOST", "192.168.0.30")
USER, PW = "ark", "ark"


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    local = sys.argv[1]
    args = " ".join("'%.100s'" % a.replace("'", "") for a in sys.argv[2:])
    script = open(local, "rb").read().replace(b"\r\n", b"\n")
    name = os.path.basename(local)
    remote = "/home/ark/" + name
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PW, timeout=25, banner_timeout=25,
              auth_timeout=25, allow_agent=False, look_for_keys=False)
    s = c.open_sftp()
    s.putfo(io.BytesIO(script), remote)
    s.close()
    chan = c.get_transport().open_session()
    chan.settimeout(3600)
    chan.get_pty()
    chan.exec_command("cd /home/ark && bash %s %s" % (name, args))
    out = b""
    while True:
        data = chan.recv(65536)
        if not data:
            break
        out += data
        sys.stdout.buffer.write(data)
        sys.stdout.flush()
    rc = chan.recv_exit_status()
    c.close()
    print("\n[exit %d]" % rc)
    return rc


if __name__ == "__main__":
    sys.exit(main())
