import sys, os, time, io, socket, paramiko
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
H = "192.168.0.30"


def up():
    s = socket.socket(); s.settimeout(3)
    try:
        s.connect((H, 22)); return True
    except Exception:
        return False
    finally:
        s.close()


def sh(cmd, t=60):
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        c.connect(H, username="ark", password="ark", timeout=t,
                  banner_timeout=t, auth_timeout=t, allow_agent=False, look_for_keys=False)
    except Exception as e:
        return "CONNECT_FAIL " + str(e)[:80]
    i, o, e2 = c.exec_command("echo ark | sudo -S -p '' sh -c '" + cmd.replace("'", "'\"'\"'") + "'", timeout=t)
    r = o.read().decode(errors="replace").strip()
    c.close()
    return r


print("重启前 uptime -s:", sh("uptime -s"))
sh("(systemctl reboot >/dev/null 2>&1 &) ; true")
print("已发出 reboot，等待下线...")
for _ in range(30):
    if not up():
        print("  设备已下线")
        break
    time.sleep(2)
else:
    print("  警告：30 次探测仍在线，可能没重启")

print("等待重新上线...")
t0 = time.time()
while time.time() - t0 < 240:
    time.sleep(5)
    if up():
        time.sleep(8)
        print("  上线，用时 %.0f s" % (time.time() - t0))
        break
else:
    print("  4 分钟未上线")

print("重启后 uptime -s:", sh("uptime -s"))
print("运行时 DT 摇杆属性:", sh("ls /proc/device-tree/play_joystick/ | tr '\\n' ' '"))
print("dmesg 摇杆:", sh("dmesg | grep -E 'Stick [0-9]|invert|joystick registered' | head -8", 90))
