import os, sys, time, hashlib, paramiko

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "ngpout")
HOST, USER, PW = "192.168.0.30", "ark", "ark"


def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def sh(c, cmd):
    i, o, e = c.exec_command("echo %s | sudo -S -p '' sh -c %s" % (repr(PW), "'" + cmd.replace("'", "'\"'\"'") + "'"), timeout=180)
    out = o.read().decode(errors="replace").strip()
    err = e.read().decode(errors="replace").strip()
    return out, err


c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PW, timeout=25, allow_agent=False, look_for_keys=False)
s = c.open_sftp()

BACKUPS = "/opt/ngp-boot-backups"

for name, dest in (("Image", "/boot/Image"), ("rk3562-ngp45ht.dtb", "/boot/rk3562-ngp45ht.dtb")):
    local = os.path.join(SRC, name)
    if not os.path.exists(local):
        sys.exit("缺少本地文件 " + local)
    size = os.path.getsize(local)
    # /boot is a 98 MB FAT partition; the old in-place .bak files filled it and cp
    # then died mid-write, leaving a truncated Image behind that only showed up as
    # "写入校验失败".  Backups go to the btrfs rootfs and the swap is a rename.
    avail = int(sh(c, "df -B1 --output=avail /boot | tail -1")[0].split()[0])
    print("上传 %s (%d 字节, /boot 可用 %d)" % (name, size, avail))
    if avail < size + (2 << 20):
        sys.exit("/boot 空间不足，先在 /opt/ngp-boot-backups 里清理旧备份")
    tmp = "/tmp/" + name
    s.put(local, tmp)
    out, err = sh(c, "mkdir -p %s; cmp -s %s %s && echo UNCHANGED || { cp -a %s %s/%s.bak-$(date +%%s) 2>/dev/null; cp %s %s.new && mv %s.new %s && sync && sha256sum %s; }"
                  % (BACKUPS, tmp, dest, dest, BACKUPS, name, tmp, dest, dest, dest, dest))
    print(" ", out or err)
    remote = sh(c, "sha256sum " + dest)[0].split()[0]
    local_sha = sha(local)
    print("  本地 %s\n  设备 %s  %s" % (local_sha[:16], remote[:16], "OK" if remote == local_sha else "不一致!"))
    if remote != local_sha:
        sys.exit("写入校验失败: " + dest)
s.close()

print("\n当前 /boot:")
print(sh(c, "ls -l /boot/Image* /boot/*.dtb* /boot/extlinux/extlinux.conf")[0])
print("\n运行内核:", sh(c, "uname -r; tr -d '\\0' < /proc/device-tree/model")[0])
ans = os.environ.get("DO_REBOOT")
if ans == "1":
    print("重启中...")
    sh(c, "sleep 1; reboot >/dev/null 2>&1 &")
else:
    print("\n(未重启；确认无误后设 DO_REBOOT=1 再跑一次，或手动重启)")
c.close()
