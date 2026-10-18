# 面板调节 + 状态灯 + 摇杆灯（NGP45HT，移植自 AURKNIX / ROCKNIX）

## 硬件（实测自 AURKNIX 192.168.31.194 的设备 quirk）

| 功能 | 走线 | 控制方式 |
|---|---|---|
| 画面四属性 | VOP2 BCSH，DRM 连接器属性 | `paneladj.sh`（libdrm ctypes，无需 sudo） |
| 状态灯（双通道） | `GPIO3_C1` = gpio113 = **蓝**，`GPIO3_C2` = gpio114 = **红** | sysfs gpio 写 value |
| 摇杆灯（WS2812） | SPI0 → `/dev/spidev0.0` | `ws2812-common --device /dev/spidev0.0 <模式>` |

充电指示由硬件自己处理，不要介入（上游 `011-led_control` 也是这么做的）。

## 文件

| 文件 | 装到 |
|---|---|
| `ledcontrol` | `/usr/bin/ledcontrol` |
| `analog_sticks_ledcontrol_single` | `/usr/bin/analog_sticks_ledcontrol_single` |
| `panelui.py` | `/opt/ngp-panel/panelui.py` |
| `opt/面板调节.sh` | `/opt/system/面板调节.sh`（唯一入口，取代 `屏幕色温.sh`） |
| `ngp-panel-restore.service` | `/etc/systemd/system/`（开机恢复画面 + 状态灯） |
| `ngp-stickled.service` | `/etc/systemd/system/`（开机恢复摇杆灯） |
| `panel.sym` + `mkpsf.py` | 生成 `Unifont-CJK-panel.psf.gz` → `/usr/share/consolefonts/` |

`ws2812-common` 二进制来自 AURKNIX `/usr/bin/ws2812-common`
（aarch64，只依赖 libc + libm；AURKNIX glibc 2.40 → dArkOS 2.41，向前兼容可直接用）。

## 操作

上下 = 切项目；**左右 = 调节（摇杆或方向键都行，长按连续）**；
A / B / START = 保存退出；SELECT = 当前项恢复默认。
状态灯持久化在 `/opt/ngp-panel/led.conf` 的 `led_color`，摇杆灯在 `stick_mode`。

## ⚠️ 两个坑

1. **DT 里不要给 SPI0 接 CS**。AURKNIX 那组的 CS 是 `GPIO3_B7`，而这根脚在本机
   同时是 i2c4（挂 rk628 HDMI 桥）的 SDA；spi 一抢走，`i2c-4` 注册不上，HDMI 废掉。
   WS2812 没有 CS，不需要。只保留 `GPIO3_B4/B5` 两根即可。
2. **`rockchip,pins` 的第 4 个值是 pcfg 的 phandle，不是裸数值**。
   从别的机器抄 `0xd7` / `0xd8` 过来会指向完全不同的节点（本机 `0xd8` 是 uart0 的
   引脚组），表现为 `pinconfig core: failed to register map default (2): no configs given`
   + `rockchip-spi: probe of ff220000.spi failed with error -22`。
   跨机抄 DT 数值前必须核对 phandle 指向。

## 在没有交叉编译环境时改 DTB

`ngp-dtb-spi0.py` 直接对 `dtc -I dtb -O dts` 解出来的文本做手术，再编回去。
源码层的正式改动在 `../dts/rk3562-ngp45ht.dts`（`&spi0` + `spi0-ngp45h` 引脚组），
重新编内核时以那份为准。

改完务必：备份 `/boot/rk3562-ngp45ht.dtb`、反编译回读 diff 只应看到预期改动、
确认 `i2c-4` 仍在 `/sys/bus/i2c/devices/`。

## ES 状态图标 + 电池百分比（主题层）

`es-theme-minimal-arkos` 原本**没有** `<batteryIndicator>` 元素，所以 ES 右上角既没有电池也没有
WiFi 图标（电池和 WiFi 是同一个元素画的，WiFi 走 `<networkIcon>`）。

`ngp-theme-battery.py` 从 `theme.xml.bak-20261018`（未打补丁的原版）重建 `theme.xml`，
在 `<view name="screen">` 里插入：

```xml
<batteryIndicator name="batteryIndicator">
  <pos>0.880 0.022</pos>     <!-- 0.925 时「图标和文字」模式的文字会顶出屏幕 -->
  <size>0.042</size>
  <itemSpacing>0.006</itemSpacing>
  <color>FFFFFF</color>
  <fontPath>./assets/noto.ttf</fontPath>   <!-- 不给字体就不画百分比 -->
  <fontSize>0.030</fontSize>
  <textColor>FFFFFF</textColor>
  <full>:/battery/full.svg</full>
  ... <incharge>:/battery/incharge.svg</incharge>
  <networkIcon>:/network.svg</networkIcon>
</batteryIndicator>
```

要点：
- 资源前缀是 **`:/battery/…`** 与 **`:/network.svg`**（不是 `:/resources/…`）。
- **`<fontPath>` / `<fontSize>` 必须显式给**，否则「图标和文字」模式只出图标。
- 设置项 `ShowBatteryIndicator` 取值 `icon` / `text` / `both`，写在 `es_settings.cfg`。
- 充电时用 `incharge.svg`（带闪电），未充电按电量走 `full/75/50/25/empty`。
- ⚠️ **不要用正则 `<batteryIndicator[^>]*>.*?</batteryIndicator>` 去改这个文件**——
  我加的中文注释里如果出现同样的标签文本，正则会从注释开始匹配，把注释吃掉，XML 直接坏掉
  （`ExpatError: not well-formed, line 12`）。要么从备份重建，要么先删注释再改。

## 图形版界面 ngp-panel-gui（SDL2 + KMSDRM）

文本界面能用了之后用户嫌"还是文本"。因为 dArkOS 的 ES 里没有面板调节的菜单实现
（见下节），所以这里自己画一个**同款观感**的界面：

- `ngp_panel_gui.c`：SDL2 + SDL2_ttf，KMSDRM 全屏 1024×768。
  底色/高亮条/字体都照 `es-theme-minimal-arkos` 与 ES 的 resources（内存里取的实际像素与字体文件）。
- **字体必须双套**：`DroidSansFallbackFull.ttf` 是**纯 CJK 回退字体，没有拉丁字形**，
  直接用它渲染 `50`、`<`、`>` 全是豆腐块。所以按码点分段：CJK（≥ U+2E80）用 Droid，
  其余用 `OpenSans-CondBold.ttf`，逐段测量再逐段绘制（`text_mixed()`）。
- 输入**不走 SDL joystick**：这台机器的 GUID 不在 SDL 的映射表里，键值对不上。
  直接读 `/dev/input/by-path/platform-play_joystick-event-joystick` 的 evdev，
  码值就是 BTN_DPAD_UP/DOWN/LEFT/RIGHT(544-547)、BTN_SOUTH(304)=B、BTN_EAST(305)=A、BTN_START(315)。
- 值变更通过 fork+exec 异步下发（`paneladj.sh` / `ledcontrol` / `analog_sticks_ledcontrol_single`），
  不 wait，界面不卡。
- `panel-item.sh` 先试 GUI；GUI 返回 **2** 表示拿不到显示（多半 ES 还握着 DRM master），
  自动回退到 `panelui.py` 文本界面。

### 编译

```sh
tools/panel-led/build-gui.sh          # 在设备上跑，输出到 /opt/ngp-panel/ngp-panel-gui
```

两个坑：
1. **SDL2_ttf 只有运行库没有头文件**（ES 是 dlopen 用的）→ 源码里手写 `TTF_*` 原型，
   链接时写全 `libSDL2_ttf-2.0.so.0`（没有 `.so` 符号链接）。
2. `TTF_GetError` 在这个版本里**没有导出**（老版本是宏）→ 统一用 `SDL_GetError()`。

## 菜单入口（最终版：只有一层）

用户在两种拆法之间反复后定的结果：**只保留一个入口**，点进去直接就是「面板与灯光调节」总览界面。

```
/opt/system/面板调节.sh   ->  /opt/ngp-panel/panel-item.sh  ->  ngp-panel-gui（6 项总览）
                                                                ↘ 返回 2 时回退 panelui.py 文本版
```

**不要**再建 `/opt/system/面板调节/` 目录（目录会变成子菜单，多一层），
也**不要**拆成 `面板-亮度.sh` 之类的一堆顶层条目（会把"选项"塞满）。

界面里：上下切项目、左右调值、A/B/START 保存退出、SELECT 把当前项恢复默认。

## 摇杆灯「调到流水就调不动」的三个坑（2026-10-18 全修）

1. **GUI 读错了配置文件**：`led_color` / `stick_mode` 在 `/opt/ngp-panel/led.conf`，
   而 GUI 用同一个 `conf_gets()` 去 `panel.conf` 里找 → 永远读不到 → 打开就显示「关」。
   现在 `conf_gets_from(path, …)`，LED 相关读 `LEDCONF`。
2. **`systemctl restart` 没带 sudo**：界面以 `ark` 身份调脚本，restart 失败但被吞掉，
   于是只改了配置、灯没重启。现在非 root 走 `sudo systemctl restart`。
3. **`led.conf` 是 root 建的，ark 写不进去**：`conf_set` 的临时文件改放 `/tmp`，
   落盘时非 root 用 `sudo install -m 666`；文件本身 `chmod 666`。
4. **最狠的一条：旧脚本留下的游离进程**。早期版本用 `sudo ws2812-common … &` 直接拉起，
   这些进程不退出、每个都占着 `/dev/spidev0.0`，实测积到 **45 个** —— 表现就是
   「切到流水以后再也调不动」（后续实例抢不到 SPI）。
   `ngp-stickled.service` 现在有 `ExecStartPre=-/usr/bin/pkill -9 -x ws2812-common`
   清理游离实例，并加 `KillSignal=SIGKILL` + `TimeoutStopSec=5`。
   ⚠️ 清理必须用 `pkill -x`（精确进程名）；用 `-f` 会把执行 pkill 的 shell 自己匹配上，
   结果是自杀、什么都不清。

## 「调到关，灯还亮着」——`ws2812-common OFF` 根本不写 SPI

`ws2812-common OFF` 只打印 `leds exit..` 就退出，**不发送任何 SPI 数据**，
WS2812 是锁存型的，所以灯保持上一帧。必须自己发一帧全黑。

编码是**实测**出来的（`spishim.c`：LD_PRELOAD 截 `ioctl(SPI_IOC_MESSAGE)`）：

| 项目 | 值 |
|---|---|
| SPI 速率 | **8,000,000 Hz**（与 DT 的 `spi-max-frequency = <8000000>` 一致） |
| bits_per_word | 8 |
| 每 WS2812 位 | **1 个 SPI 字节**：`0xC0` = 0，`0xFC` = 1 |
| 一次传输 | 192 字节 = 8 颗灯 × 24 位；顺序 G,R,B |

所以 `ngp-led-off.c`（→ `/opt/ngp-panel/ngp-led-off`）就是写 1024 个 `0xC0` 再延时 latch。

⚠️ **`sudo` 会吞掉 `LD_PRELOAD`**（连 `sudo env LD_PRELOAD=…` 都不行），
逆向前必须先把 `/dev/spidev0.0` 临时改成 666、以 ark 身份直接跑，截完再改回 600。
截获时 shim 会让程序在退出时 segfault（我的结构体解析越界），不影响抓到第一帧。

另外：`analog_sticks_ledcontrol_single` 的 systemd 判据从 `is-active` 改成
**`systemctl cat`（单元存在即可）** —— OFF 模式下 unit 跑完就 inactive，
用 `is-active` 会退化成自己 spawn，又制造游离进程。

## 选项菜单汉化 + 网络设置图形界面

### 菜单汉化（`rename-menu-zh.sh`，幂等）

ES 的「选项」= `/opt/system/*.sh`（文件名去扩展名即显示名）+ 子目录（子菜单）。
所以汉化就是改文件名，但有三个坑：

1. **脚本内部的自引用**：`gptokeyb -1 "<自己的文件名>"` 用来判断前台程序是否退出，
   改名后必须同步改这行，否则手柄映射会失灵。脚本里用 `sed` 一起改了。
2. **`Tools` 改不了名**：它是 `/roms2/tools` 的 **bind mount 挂载点**
   （`findmnt /opt/system/Tools` 可见），`mv` 会报 `Device or resource busy`。
   要改得先改 fstab 里的挂载点并动 `Advanced/Switch to * SD for Roms.sh`，风险大，**保留英文**。
3. 已去掉：`LED Settings.sh`（面板调节已覆盖）、`网络信息.sh`（网络设置已覆盖）。

### 网络设置（`ngp_wifi_gui.c` → `/opt/ngp-panel/ngp-wifi-gui`）

`/opt/system/网络设置.sh` 先起图形版，返回 2 再回退到老的 dialog 版
（`/opt/np-panel`... 实际是 `/opt/ngp-wifi/wifi-dialog.sh`，原 `Wifi.sh` 移过去并把
内部 `gptokeyb -1 "Wifi.sh"` 改成 `wifi-dialog.sh`）。

界面内容：
- **WiFi 开关**（左/右切换，`nmcli radio wifi on|off`）
- **当前连接**：SSID + IP（空则显示"未连接"）
- **可用网络**：SSID + 信号格 + 数字 + 锁/开，A 连接；加密网络弹屏幕键盘输密码
- **SSH 开关**（`systemctl enable/disable --now ssh.service`）

两个 nmcli 坑（这版 nmcli 比较老）：
- **不支持 `--separator`** —— 一开始用它，扫描和"当前连接"全都拿不到数据。
- SSID 里的 `:` 会被转义成 `\:`，所以 `-t -f SSID,SIGNAL,SECURITY` 的输出要
  **从右侧解析**：最后一个 `:` 后是 SECURITY，倒数第二个是 SIGNAL，剩下是 SSID，再反转义。
  查活动连接同理，用 `sed -n 's/:wlan0$//p'` 剥尾巴最稳。

## 进游戏前的加载画面：`/roms/launchimages/loading.jpg`

不是 ES 画的、也不是 retrorun —— 是 **`image-viewer`** 显示的一张 **960×544 JPEG**：
`/roms/launchimages/loading.jpg`（`/mnt/roms1`、`/mnt/roms2` 各一份，`/roms`、`/roms2` 是同一份）。

**怎么定位到的**：起一个 10 分钟监视器（`/tmp/who.sh`），每 0.15 s 记录
`fuser -v /dev/dri/card0`、`fuser -v /dev/fb0`、`ps -eo pid,etimes,args`，
让用户进一次游戏，再从日志里筛短命进程 → 直接看到 `image-viewer /roms/launchimages/loading.jpg`。

**原图结构（必须实测，别猜）**：底 `#212121`(lum 33)、logo **填充 lum≈88**、
logo 描边 lum≈0-15、`Please wait...` 是纯 255 的点阵字。

`ngp-loading-image.py` 的做法：
1. 灰度做 **MedianFilter(3)** 去掉 JPEG 块噪（否则白填充会发花）；
2. 两张 mask 合成：`fill = ramp(58,78)` → 白，`edge = 255-ramp(15,30)` → 深蓝黑；
   ⚠️ 写反过一次（`ramp(255-v)`），结果整个背景被涂成深色 —— mask 方向必须验证；
3. 原文字区域用 `ImageChops.multiply` 挖空；
4. 整幅按 1024/960 放大（LANCZOS）后放进 **1024×768** 画布垂直居中 —— 面板就是 1024×768，
   这样 image-viewer 不用缩放，锯齿消失；
5. 文字用 `OpenSans-CondLight.ttf` **重新渲染**（自动匹配到原宽度），加 2px 高斯投影。

天蓝取 `#4FC3F7`，改 `BG` 常量重跑即可（脚本始终从 `loading.jpg.bak-ngp` 读原图，可反复执行）。

⚠️ **不要用 `grep -a` 按字节在 ES 二进制里找颜色常量**：我曾把 `21 21 21` 当成加载底色去改，
实际那三字节是错误日志 `"Error reading battery data!!!"` 里的 `!!!`（已从
`/opt/ngp-panel/emulationstation.bak-ngp` 还原）。找常量一定先看上下文 ASCII。

## 支持「天马G / Pegasus」游戏包（`pegasus2es.py`）

天马G 用的是 **Pegasus 前端**格式，dArkOS 是 EmulationStation，两者数据结构不同：

```
天马G:  <系统>/metadata.pegasus.txt + media/<游戏名>/{boxfront,logo,video}
ES  :   <系统>/gamelist.xml        + images/ 或直接 <image> 指路径
```

`pegasus2es.py <系统目录>` 把前者转成后者，**图片/视频直接引用 media 下的文件，不复制**：
`<name> <desc> <image> <marquee>(logo) <video> <developer> <genre> <players> <releasedate> <sortname>`，
并保留已有的 `playcount / lastplayed / favorite / hidden`。

踩到的坑：
- 天马G 的封面文件名**大小写/扩展名都不统一**：`boxfront.png`(257) / `boxFront.png`(184) /
  `boxfront.jpg`(35) / `boxFront.jpg`(8) —— 必须**大小写不敏感**匹配，否则只能认出 43 个。
- `description` 里的换行是字面 `\n`，要转成真换行。
- 元数据里的 `file:` 要和目录里的真实文件对得上，对不上就跳过（避免生成死条目）。

实测（GBA 495 个 ROM）：写 455 条，**451 个有封面 + logo**；0 个缺路径。

## 街机封面（`arcade-covers.py`）

街机 ROM 是 `1941.zip` 短名，而 libretro 缩略图按**游戏全名**命名
（`1941 - Counter Attack (World).png`），所以要：
1. 用 ES 的 `mamenames.xml` 把短名换成官方全名；
2. 拉 `https://thumbnails.libretro.com/FBNeo%20-%20Arcade%20Games/Named_Boxarts/` 的目录清单
   （约 6400 张，索引 1.6 MB）本地匹配：先按「第一个括号前」的标题精确匹配，
   再按地区词（World/USA/Japan/Euro）挑版本，最后 `difflib` 兜底；
3. 改版/自制版在名库里没有条目 → 用 `ALIAS` 表借原版封面（降龙/彩虹/东方不败 → 街霸2 冠军版 等）；
4. 下载到 `<系统>/images/<rom>-image.png`，再由 `arcade-zh-names.py` 把 `<image>` 写进 gamelist。

实测 cps1 48 个：**47 个拿到封面**（只缺 `ganbare` Ganbare! Marine Kun，CDN 里没有），23 MB。
