#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""panelui.py — NGP45HT 面板与灯光调节（摇杆左右调节）

把 ROCKNIX / AURKNIX 在 ES 里内建的那套「面板调节 + LED + 摇杆灯」菜单
移植到 dArkOS：dArkOS 的 EmulationStation 里没有 ROCKNIX 的
GuiAnalogSticksLedControls / paneladj 滑块（实测 ES 二进制里 0 处匹配），
所以这里自己画一个控制台界面，直接读 evdev，摇杆左右即可连续调节。

    item 0-3   亮度 / 对比度 / 饱和度 / 色相   VOP2 BCSH 连接器属性 0-100
    item 4     状态灯   GPIO3_C1(113 蓝) + GPIO3_C2(114 红)
    item 5     摇杆灯   SPI0(/dev/spidev0.0) 上的 WS2812

按键（rk3562-joystick，与 /opt/inttools/keys.gptk 及 RA autoconfig 一致）：
    上/下     dpad 544/545 或左摇杆 Y（RA: l_y_minus = -1，故上为负）
    左/右     dpad 546/547 或左摇杆 X（RA: l_x_minus = -0，故左为负）
    A(305) / START(315) / B(304)   保存并退出
    SELECT(314)                    把当前项恢复默认

环境变量 NGP_UI_INVERTX=1 可翻转摇杆 X 的方向（若运行的内核还没带
per-axis invert 补丁，左摇杆左右会反）。
"""
import os
import struct
import subprocess
import sys
import time

TTY = os.environ.get("NGP_UI_TTY", "/dev/tty1")
JOY = os.environ.get("NGP_UI_JOY",
                     "/dev/input/by-path/platform-play_joystick-event-joystick")
PANELADJ = "/opt/ngp-panel/paneladj.sh"
LEDCONTROL = "/usr/bin/ledcontrol"
STICKLED = "/usr/bin/analog_sticks_ledcontrol_single"
LEDPROBE = "/dev/spidev0.0"

EV_KEY, EV_ABS = 0x01, 0x03
ABS_X, ABS_Y = 0x00, 0x01
K_UP, K_DOWN, K_LEFT, K_RIGHT = 544, 545, 546, 547
K_B, K_A, K_SELECT, K_START = 304, 305, 314, 315
QUIT_KEYS = (K_A, K_B, K_START)

# 摇杆阈值与重复速率
DEAD = 0.55          # 归一化死区
REPEAT_FIRST = 0.35  # 首次响应延迟
REPEAT_NEXT = 0.10   # 之后每次间隔
NAV_REPEAT = 0.28    # 上下切换间隔

INVERTX = os.environ.get("NGP_UI_INVERTX") == "1"

# --only <key>：只调某一项（供 选项 → 面板调节 → 亮度 / 对比度 / … 的单项入口用）。
# 这时上下键不换项目，只保留左右调节。
ONLY = None
ONLY_KEYS = {"brightness": 0, "contrast": 1, "saturation": 2, "hue": 3,
             "led": 4, "stick": 5}

# ---- 项目定义 -------------------------------------------------------------
# (标题, 类型, 属性名/命令, 最小值, 最大值)
PROPS = ["brightness", "contrast", "saturation", "hue"]
PROP_TITLE = {"brightness": "亮度", "contrast": "对比度",
              "saturation": "饱和度", "hue": "色相"}
PROP_MIN = {"brightness": 5, "contrast": 0, "saturation": 0, "hue": 0}

LED_COLORS = ["off", "red", "blue", "purple"]
LED_LABEL = {"off": "关", "red": "红", "blue": "蓝", "purple": "紫"}

STICK_MODES = ["OFF", "Scrolling", "Breathing", "Breathing_Red",
               "Breathing_Green", "Breathing_Blue", "Breathing_Blue_Red",
               "Breathing_Green_Blue", "Breathing_Red_Green",
               "Breathing_Red_Green_Blue", "Red_Green_Blue", "Blue_Red",
               "Blue", "Green_Blue", "Green", "Red_Green", "Red"]
STICK_LABEL = {
    "OFF": "关", "Scrolling": "流水", "Breathing": "呼吸",
    "Breathing_Red": "呼吸红", "Breathing_Green": "呼吸绿",
    "Breathing_Blue": "呼吸蓝", "Breathing_Blue_Red": "呼吸蓝红",
    "Breathing_Green_Blue": "呼吸绿蓝", "Breathing_Red_Green": "呼吸红绿",
    "Breathing_Red_Green_Blue": "呼吸三色", "Red_Green_Blue": "三色循环",
    "Blue_Red": "蓝红", "Blue": "蓝", "Green_Blue": "绿蓝", "Green": "绿",
    "Red_Green": "红绿", "Red": "红",
}

N_ITEM = 6
W = 54   # 界面宽度（字符）


def sh(*args):
    try:
        subprocess.run(args, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=10)
    except Exception:
        pass


def sh_out(*args):
    try:
        return subprocess.run(args, capture_output=True, text=True,
                              timeout=10).stdout.strip()
    except Exception:
        return ""


class State(object):
    def __init__(self):
        self.sel = ONLY_KEYS.get(ONLY, 0) if ONLY else 0
        self.vals = {}
        for p in PROPS:
            v = sh_out(PANELADJ, "value", p)
            try:
                v = int(v)
            except Exception:
                v = 50
            lo, hi = PROP_MIN[p], 100
            self.vals[p] = max(lo, min(hi, v))
        self.led = sh_out("sed", "-n", "s/^led_color=//p",
                          "/opt/ngp-panel/led.conf") or "blue"
        if self.led not in LED_COLORS:
            self.led = "blue"
        self.stick = sh_out("sed", "-n", "s/^stick_mode=//p",
                            "/opt/ngp-panel/led.conf") or "OFF"
        if self.stick not in STICK_MODES:
            self.stick = "OFF"
        self.has_stick = os.path.exists(LEDPROBE)

    # --- 取值 / 显示 ---
    def cur(self):
        if self.sel < 4:
            return self.vals[PROPS[self.sel]]
        if self.sel == 4:
            return self.led
        return self.stick

    def label(self):
        if self.sel < 4:
            p = PROPS[self.sel]
            return "%s %d" % (PROP_TITLE[p], self.vals[p])
        if self.sel == 4:
            return LED_LABEL[self.led]
        return STICK_LABEL[self.stick]

    def gauge(self):
        """数值项的进度条；非数值项返回 None"""
        if self.sel >= 4:
            return None
        p = PROPS[self.sel]
        lo, hi = PROP_MIN[p], 100
        v = self.vals[p]
        n = 30
        pos = int(round((v - lo) * (n - 1) / float(hi - lo)))
        return "[" + "=" * pos + "|" + "-" * (n - 1 - pos) + "]"

    # --- 应用 ---
    def apply(self):
        if self.sel < 4:
            sh(PANELADJ, PROPS[self.sel], str(self.vals[PROPS[self.sel]]))
        elif self.sel == 4:
            sh("sudo", LEDCONTROL, self.led)
        else:
            sh("sudo", STICKLED, self.stick)

    def step(self, direction):
        """direction: -1 左 / +1 右"""
        if self.sel < 4:
            p = PROPS[self.sel]
            lo, hi = PROP_MIN[p], 100
            v = self.vals[p] + direction
            v = max(lo, min(hi, v))
            if v == self.vals[p]:
                return False
            self.vals[p] = v
        elif self.sel == 4:
            i = LED_COLORS.index(self.led)
            i = (i + direction) % len(LED_COLORS)
            self.led = LED_COLORS[i]
        else:
            i = STICK_MODES.index(self.stick)
            i = (i + direction) % len(STICK_MODES)
            self.stick = STICK_MODES[i]
        self.apply()
        return True

    def reset_item(self):
        if self.sel < 4:
            p = PROPS[self.sel]
            self.vals[p] = 50 if p != "brightness" else 50
        elif self.sel == 4:
            self.led = "blue"
        else:
            self.stick = "OFF"
        self.apply()

    def move(self, d):
        if ONLY:          # 单项模式：锁在该项
            return
        self.sel = (self.sel + d) % N_ITEM


# ---- 渲染 -----------------------------------------------------------------
def row(title, body, sel):
    mark = ">" if sel else " "
    left = "%s %s" % (mark, title)
    return "  " + left.ljust(10) + body


def render(st, tty):
    esc = "\x1b["
    out = [esc + "H", esc + "2J"]
    out.append("\x1b[1;1H")
    bar = "─" * (W - 4)
    out.append("  ┌" + bar + "┐\r\n")
    out.append("  │" + "面板与灯光调节".center(W - 4) + "│\r\n")
    out.append("  ├" + bar + "┤\r\n")

    for i in range(4):
        p = PROPS[i]
        g = "[" + "=" * int(round((st.vals[p] - PROP_MIN[p]) * 29 / (100.0 - PROP_MIN[p]))) \
            + "|" + "-" * (29 - int(round((st.vals[p] - PROP_MIN[p]) * 29 / (100.0 - PROP_MIN[p])))) + "]"
        body = "%s %3d" % (g, st.vals[p])
        line = row(PROP_TITLE[p], body, i == st.sel)
        out.append("  │" + line.ljust(W - 4) + "│\r\n")

    body = "< %s >" % LED_LABEL[st.led]
    out.append("  │" + row("状态灯", body, st.sel == 4).ljust(W - 4) + "│\r\n")

    if st.has_stick:
        body = "< %s >" % STICK_LABEL[st.stick]
        out.append("  │" + row("摇杆灯", body, st.sel == 5).ljust(W - 4) + "│\r\n")
    else:
        out.append("  │" + row("摇杆灯", "无 SPI 设备", st.sel == 5).ljust(W - 4) + "│\r\n")

    out.append("  ├" + bar + "┤\r\n")
    out.append("  │" + "上下=切换项目   左右=调节".ljust(W - 4) + "│\r\n")
    out.append("  │" + "A/START=保存退出   SELECT=本项默认".ljust(W - 4) + "│\r\n")
    out.append("  └" + bar + "┘\r\n")
    tty.write("".join(out))
    tty.flush()


def width_of(s):
    """控制台字库里 CJK 为全宽一字符，这里中文按 1 列算（16x16 字体）"""
    return len(s)


# ---- 输入 -----------------------------------------------------------------
def open_joy():
    try:
        import fcntl
        fd = os.open(JOY, os.O_RDONLY | os.O_NONBLOCK)
        return fd
    except Exception:
        return None


def norm_axis(fd, code, span):
    try:
        import fcntl
        buf = fcntl.ioctl(fd, 0x80184540 + code, b"\0" * 24)
        mn, mx = struct.unpack("<6i", buf)[1:3]
    except Exception:
        mn, mx = -32767, 32767
    return mn, mx


def parse_args(argv):
    global ONLY
    if "--only" in argv:
        i = argv.index("--only")
        if i + 1 < len(argv):
            k = argv[i + 1]
            if k not in ONLY_KEYS:
                sys.stderr.write("unknown --only key: %s\n" % k)
                sys.exit(2)
            ONLY = k


def main(argv=None):
    parse_args(sys.argv[1:] if argv is None else argv)
    st = State()
    tty = open(TTY, "w", buffering=1, encoding="utf-8", errors="replace")
    tty.write("\x1b[?25l")
    render(st, tty)

    fd = open_joy()
    if fd is None:
        tty.write("\r\n  未找到手柄 %s\r\n" % JOY)
        time.sleep(3)
        return 1

    import select
    import fcntl
    mn_x, mx_x = norm_axis(fd, ABS_X, None)
    mn_y, mx_y = norm_axis(fd, ABS_Y, None)
    rng_x = float(mx_x - mn_x) or 1.0
    rng_y = float(mx_y - mn_y) or 1.0
    mid_x = (mx_x + mn_x) / 2.0
    mid_y = (mx_y + mn_y) / 2.0

    ax = ay = 0.0           # 归一化 -1..1
    hold_l = hold_r = 0.0   # 按住计时
    hold_u = hold_d = 0.0
    EV_SIZE = 24
    last = time.time()

    while True:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                raw = os.read(fd, EV_SIZE * 64)
            except BlockingIOError:
                raw = b""
            except OSError:
                break
            for off in range(0, len(raw) - EV_SIZE + 1, EV_SIZE):
                # NOTE: "<llHHi" is 16 bytes (standard-size 'l' is 4 bytes),
                # but struct input_event is 24 bytes on 64-bit.  Use 'q' for
                # the two timeval fields or unpack() raises struct.error and
                # the whole UI dies on the first event.
                _t1, _t2, etype, code, value = struct.unpack(
                    "<qqHHi", raw[off:off + EV_SIZE])
                if etype == EV_ABS and code == ABS_X:
                    ax = (value - mid_x) / (rng_x / 2.0)
                    if INVERTX:
                        ax = -ax
                elif etype == EV_ABS and code == ABS_Y:
                    ay = (value - mid_y) / (rng_y / 2.0)
                elif etype == EV_KEY:
                    if value != 1:
                        continue
                    if code == K_UP:
                        st.move(-1); render(st, tty)
                    elif code == K_DOWN:
                        st.move(1); render(st, tty)
                    elif code == K_LEFT:
                        st.step(-1); render(st, tty)
                    elif code == K_RIGHT:
                        st.step(1); render(st, tty)
                    elif code == K_SELECT:
                        st.reset_item(); render(st, tty)
                    elif code in QUIT_KEYS:
                        tty.write("\x1b[?25h")
                        return 0

        now = time.time()
        dt = now - last
        last = now

        # 摇杆左右 -> 连续调节
        for sign, name in ((-1, "l"), (1, "r")):
            active = (sign < 0 and ax < -DEAD) or (sign > 0 and ax > DEAD)
            t = hold_l if sign < 0 else hold_r
            if active:
                if t == 0:
                    st.step(sign); render(st, tty); t = 0.0001
                else:
                    t += dt
                    if t > REPEAT_FIRST:
                        st.step(sign); render(st, tty); t = REPEAT_FIRST - REPEAT_NEXT
            else:
                t = 0.0
            if sign < 0:
                hold_l = t
            else:
                hold_r = t

        # 摇杆上下 -> 切换项目
        for sign, name in ((-1, "u"), (1, "d")):
            active = (sign < 0 and ay < -DEAD) or (sign > 0 and ay > DEAD)
            t = hold_u if sign < 0 else hold_d
            if active:
                if t == 0:
                    st.move(sign); render(st, tty); t = 0.0001
                else:
                    t += dt
                    if t > NAV_REPEAT:
                        st.move(sign); render(st, tty); t = 0.0001
            else:
                t = 0.0
            if sign < 0:
                hold_u = t
            else:
                hold_d = t

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException:
        import traceback
        try:
            with open("/opt/ngp-panel/ui.log", "w") as fh:
                traceback.print_exc(file=fh)
        except Exception:
            pass
        traceback.print_exc()
        sys.exit(1)
