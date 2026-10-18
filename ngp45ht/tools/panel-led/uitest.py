#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""uinput 虚拟手柄 -> 实测 panelui.py 的按键路径是否会退出。"""
import fcntl
import os
import struct
import subprocess
import sys
import time

UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_ABSBIT = 0x40045567
UI_DEV_SETUP = 0x405c5503
EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
ABS_X, ABS_Y = 0, 1
BTN_SOUTH, BTN_EAST = 0x130, 0x131
BTN_DPAD_UP, BTN_DPAD_DOWN, BTN_DPAD_LEFT, BTN_DPAD_RIGHT = 0x220, 0x221, 0x222, 0x223


def emit(fd, etype, code, value):
    os.write(fd, struct.pack("<qqHHi", 0, 0, etype, code, value))


def main():
    fd = os.open("/dev/uinput", os.O_WRONLY | os.O_NONBLOCK)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_KEY)
    fcntl.ioctl(fd, UI_SET_EVBIT, EV_ABS)
    for k in (BTN_SOUTH, BTN_EAST, BTN_DPAD_UP, BTN_DPAD_DOWN,
              BTN_DPAD_LEFT, BTN_DPAD_RIGHT):
        fcntl.ioctl(fd, UI_SET_KEYBIT, k)
    for a in (ABS_X, ABS_Y):
        fcntl.ioctl(fd, UI_SET_ABSBIT, a)

    # struct uinput_abs_setup { u16 code; u16 pad; input_absinfo {s32 value,min,max,fuzz,flat,res} }
    for a in (ABS_X, ABS_Y):
        buf = struct.pack("<HH6i", a, 0, 0, -32767, 32767, 0, 0, 0)
        fcntl.ioctl(fd, 0x401c5504, buf)   # UI_ABS_SETUP

    name = b"ngp-vtest"
    # struct uinput_setup { struct input_id id; char name[80]; __u32 ff_effects_max; }
    setup = struct.pack("<HHHH", 0x03, 0x01, 0x01, 1) + name.ljust(80, b"\0") \
        + struct.pack("<I", 0)
    fcntl.ioctl(fd, UI_DEV_SETUP, setup)
    fcntl.ioctl(fd, UI_DEV_CREATE)
    time.sleep(0.6)

    # 找到新建的 event 节点
    ev = None
    for d in sorted(os.listdir("/sys/class/input")):
        if not d.startswith("event"):
            continue
        try:
            n = open("/sys/class/input/%s/device/name" % d).read().strip()
        except Exception:
            continue
        if n == "ngp-vtest":
            ev = "/dev/input/" + d
    print("virtual evdev:", ev)
    if not ev:
        os.close(fd)
        return 1

    log = "/home/ark/ui-test.log"
    env = dict(os.environ, NGP_UI_JOY=ev, NGP_UI_TTY=log)
    p = subprocess.Popen(["python3", "/opt/ngp-panel/panelui.py"], env=env)
    time.sleep(1.5)
    print("panelui alive after start:", p.poll() is None)

    def tap(code):
        emit(fd, EV_KEY, code, 1); emit(fd, EV_SYN, 0, 0)
        time.sleep(0.15)
        emit(fd, EV_KEY, code, 0); emit(fd, EV_SYN, 0, 0)
        time.sleep(0.4)

    def abs_to(a, v):
        emit(fd, EV_ABS, a, v); emit(fd, EV_SYN, 0, 0)

    tests = [("dpad down", BTN_DPAD_DOWN), ("dpad right", BTN_DPAD_RIGHT),
             ("dpad left", BTN_DPAD_LEFT), ("dpad up", BTN_DPAD_UP)]
    for label, code in tests:
        tap(code)
        alive = p.poll() is None
        print("after %-12s alive=%s rc=%s" % (label, alive, p.poll()))
        if not alive:
            break

    if p.poll() is None:
        abs_to(ABS_X, 30000); time.sleep(0.5)
        print("after stick right alive=%s" % (p.poll() is None))
        abs_to(ABS_X, 0); time.sleep(0.3)

    if p.poll() is None:
        p.terminate()
        p.wait()
        print("killed by test")
    else:
        print("PANELUI EXITED rc=%s" % p.returncode)

    fcntl.ioctl(fd, UI_DEV_DESTROY)
    os.close(fd)
    print("---- log ----")
    try:
        print(open(log).read()[-1500:])
    except Exception as e:
        print("no log:", e)
    return 0


sys.exit(main())
