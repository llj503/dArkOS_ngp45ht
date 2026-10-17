# 更新记录

## 2026-10-17 · 同步上游 v1.1 + 色温移植 + 中文字体

**上游同步**（mamaich/dArkOS_rg52mini v1.1，`ecb0922`）：除 `.gitmodules`/`README.md` 和三个子模块指针
保留本仓库版本外，其余 135 个变更/新增文件全部合入。与移植冲突 0 处——上游没碰 `ngp45ht/`。
合入的重点：

- **`perfmax`/`perfnorm` 改为探测 GPU devfreq 节点**（`/sys/class/devfreq/*.gpu`），写死 `fde60000` 的
  问题上游已修，本机 `ff320000` 直接受益；另引入 `perfoc` 超频开关（本机无 1000 MHz 档，会优雅退出）。
- **内核模块 `--strip-debug`**：去掉 DWARF 但保留符号表（MODVERSIONS CRC 要靠它），`.ko` 体积约省 97%——
  p4 只剩 ~224 MB 的情况下这是实质性缓解。
- **PortMaster E2BIG 修复**（`portmaster-e2big`）：PortMaster 的 `get_controls()` 导出整个
  gamecontrollerdb 当 `SDL_GAMECONTROLLERCONFIG`，超过内核 128 KB 限制，之前每个端口都死在
  "Argument list too long"。
- **睡眠/电源键修复**：systemd sleep hook（`scripts/sleep.rk3562` → `/usr/lib/systemd/system-sleep/sleep`）
  + `pause.sh` 读 `/run/darkos-sleep.phase` 区分"睡梦中按的键"和"新请求" + ES 的 sleep/wake 脚本 +
  背光记忆 udev 规则。10-16 黑屏事件的两个候选解释（suspend 卡死 / 背光被调暗）都在这里有了对应物。
- **根目录归属修复**（`chown root:root Arkbuild/`）：否则 PPSSPP-2021 每次启动都在 `/` 留内存文件。
- 其余：Wifi.sh 的 rk3562 开关、bttoggle 持久化、bluealsa 条件启用、Bluetooth
  `ClassicBondedOnly=false`、RetroArch 安全补丁 0021-0023、zram/emmc-swap、runport.sh、
  wifi_importer、audit-components、shutdown 图、DSperate/vk-rotate-layer/gl4es-fix/OTA 全套。
- 本仓库定制：**panel-kick 不装到 NGP45HT**（它的 rev-A 判定对没有 husb311 的设备恒真，会白翻一次屏）；
  **OTA 扩展到 ngp45ht**（`ota/ngp45ht.json` 空 feed 起步，`darkos-ota` 默认 feed 指向本仓库）；
  `es_systems.cfg.rk3562` 补上卡上已有的 **fbneo** 系统块（现 131 个系统，XML 已验证）。

**屏幕色温/画面调节**（`tools/ngp-panel/`，移植自 ROCKNIX `paneladj`）：VOP2 BCSH 四个连接器属性
brightness/contrast/saturation/hue（0-100，50 中性，全 50 时驱动旁路）。`panelprop.py` 用 ctypes 直调
libdrm 写属性，不装 modetest、不用 sudo；值持久化在 `/opt/ngp-panel/panel.conf`（`/opt` 不受 SD-switch
sed 影响）；`ngp-panel-restore.service` 开机重放（DRM 属性重启即丢）。菜单入口 `/opt/system/屏幕色温.sh`，
dialog + gptokeyb 手柄可操作，亮度下限 5 防调黑。`install.sh` 镜像/卡片两用，已挂进 finishing_touches。

**中文字体**：`Unifont-CJK-panel.psf.gz`，mkpsf.py 从 GNU Unifont BDF 自建的 512 字形位 PSF2
（内核 VT 单字体上限 512；PSF1 会被按 8px 宽解释把汉字拉成竖条，必须 PSF2；bdf2psf 因混合宽度会丢汉字，
故自写转换器）。ES 菜单中文走镜像自带的 DroidSansFallbackFull 回退，改文件名即可。

**收尾的旧账**：`ngp-p1-switch.sh` / `ngp-xpad-build.sh`（外接手柄抢 P1、xpad 构建）提交进 `tools/`；
`ngp45ht_defconfig` 补上 `CONFIG_JOYSTICK_XPAD=y` + `_FF=y`（2.4G XInput 手柄，下一版镜像生效）。

**镜像 `dArkOS_ngp45ht_trixie_20261017.img`（12,884,901,888 B = 12 GiB 整）**：不是从构建树重打，
而是**从实机 TF 卡克隆**——卡上跑通的改动原生就在镜像里。做法：本机无管理员（`\\.\PhysicalDrive3`
打不开）且 WSL 被安全策略拦截，故用卷路径 `\\.\Volume{GUID}` 原始读 p3/p4（可移动介质免提权），
盘头 0–16 MiB（p1/p2 无卷路径）与尾部 128 MiB（含 p5 的 FAT16 "ROMS" 和备份 GPT）则从已发布的
20261015 镜像**按 xz 块索引精确提取**（只下 38 MB + 26 KB，不必下 4.5 GB）。
已确认原镜像与卡上 p1–p4 布局字节级一致，只有 p5 EASYROMS 首次启动被扩容（79 MiB → 46.7 GB）。
根分区是 **btrfs**（非 ext4），超级块在 64 KiB。分区闭包校验 + `7z t` 整包解码 + 分卷重组解码三重通过。
GitHub 单资产上限 2 GiB（实测整包被 `422 size must be less than 2147483648` 拒），故分 3 卷发布。

## 2026-10-16 · 卡上修正（没有重打镜像）

都落在**现役卡**上，脚本同时进了 `tools/`；下次重建镜像一起带进去。

- **两张 TF 卡合并成一个 `/roms`**：`ngp-rompool.sh install` 写 fstab（分支 `/mnt/roms1` + `/mnt/roms2`，
  mergerfs 池挂在 `/roms`，dArkOS 和 ES 的路径一个都不用改），冷启动已验证。TF2 不在也能正常起：
  单分支池本身就成立，另有 `ConditionPathIsMountPoint=!/roms` 的兜底 unit 把 TF1 直接挂到 `/roms`。
  坑：fstab 的 `x-systemd.requires=` 必须写**单元名**（`mnt-roms1.mount`），写路径再配 `nofail` 会被静默跳过，
  而 `systemctl status roms.mount` 还会因为兜底 unit 显示 `active (mounted)`，很难看出池没起来。
- **GPU 调速从来没生效过**：`perfmax`/`perfnorm` 把 Mali 的 devfreq 节点写死成 `fde60000.gpu`（RK3566 的地址），
  本机是 `ff320000.gpu`，脚本又没有 `set -e`，所以是静默无效而非报错。现在探测不到就退回
  `/sys/class/devfreq/*.gpu`，实测 300 → 900 MHz。
- **内核来源换成官方 buildbot**：`ngp-core-update.sh` 默认 `SOURCE=buildbot`
  （`nightly/linux/{aarch64,armhf}/latest`，231/109 条），两套 RA 的 `core_updater_buildbot_cores_url`
  也都指向它，HBMAME 这类只有 buildbot 才有的内核因此下得到。注意 RA 退出时会整份重写 cfg，
  改这两个键时 RA 必须没在跑（见 README「遮罩与滤镜」）。
- **per-core 遮罩的路径写错了**：RA 只认 `config/<library_name>/<library_name>.cfg`，之前的扁平
  `config/<library_name>.cfg` 它连 stat 都不做，症状就是"GBA 打开没遮罩，得手动切一次"。改对之后用
  `ngp-shaders.sh verify`（对 cfg **副本**无头跑 RA，看 `[Override]` 日志）验证：GBA/GB 自动上
  `handheld/lcd-grid-v2.glslp`，街机（FinalBurn Neo / MAME 系列 / HBMAME / FB Alpha）显式关闭，
  底包的全局 `Dot_Matrix_4x.filt` 已清空，帧率 OSD 两套 RA 都关。
- **768P PNG 遮罩按游戏分类自动加载**：`ngp-shaders.sh install_masks <包>` + `masks on`，18 张 1024×768
  全屏遮罩装到 `/opt/ngp-shaders/masks768`（校验每个 cfg 指向的 PNG 存在且 IHDR 确实是 1024×768），
  然后用 RA 的 **per-content-directory override**（`config/<核心>/<ROM 父目录>.cfg`，叠在 per-core 之上）
  给 `gba gb gbc nes famicom fds snes sfc megadrive genesis wonderswan wonderswancolor ngp ngpc pico-8`
  各配一张，并配 `video_scale_integer = "true"` —— 遮罩窗口就是各机种分辨率的整数倍
  （GBA 240×160×4=960×640、GB/GBC 160×144×5=800×720、NES/SNES 256×224×3=768×672、MD 320×224×3=960×672、
  WSC 224×144×4=896×576、Pico-8 128×128×6=768×768），整数缩放正好落进洞里；只有 NGPC（782×741）差约 2%。
  第三方美术，不进仓库。
- **ES 里补上 FBNeo 分类**：`es_systems.cfg` 原本没有任何系统指向 `/roms/fbneo`（2020 个游戏），
  而 ES 只列"有内容的系统"，所以前端只剩 CPS1 / GBA / ports。已在 `arcade` 之前插入 `fbneo` 系统块
  （`<theme>arcade</theme>` 复用现役主题美术；核心只列卡上真装了的 `fbneo hbmame fbalpha2012 mame2003_plus mame`），
  落盘前用 `ET.fromstring()` 验过语法，重启 `emulationstation.service` 生效，原文件备份为 `es_systems.cfg.orig-ngp`。

## 2026-10-15 · `dArkOS_ngp45ht_trixie_20261015.img.xz`

改动**只在 p4 rootfs**。p3 FAT 与 20261013 版逐字节相同：
`Image` `4216e2244c3b74cd…`(32,522,752 B，`ngp45ht_defconfig`)、`rk3562-ngp45ht.dtb` `f716f3077b4e1aa1…`、
`firstboot.sh` `8c1a37e6281a0a37…`（loop 挂载 offset 16777216 复核）。

- **48 个 libretro 内核刷新**：来源 `christianhaitian/retroarch-cores` 分支 **rg503**（dArkOS 对所有非 rk3326
  板子都用 rg503），也就是 `build_retroarch.sh:98` 当年 wget 的同一个仓；每个内核的构建日期取自分支自带的
  `aarch64/.index-extended`。镜像之后被重建过 52 个，其中 49 个字节真的不同。
- **验收以 RetroArch 自己加载为准**：`ngp-core-update.sh raload` 用 null 视频/音频/输入驱动在临时 `HOME` 里逐个
  让 RA 打开内核，48 颗全部加载成功（fbneo 自报 `v1.0.0.03 260904 GITa251c7622`）。裸 `ctypes` dlopen 会
  误报九颗正常内核缺符号，`install` 因此改成"装完就 RA 验收，打不开自动恢复刚做的备份"。
- **一颗保持原样**：`np2kai` 新版能装、md5 也对，但 RetroArch 报 `Failed to open libretro core`
  （需要 `ymzadpcm_getpcm`），所以镜像里仍是可用的旧版。
- **一颗原本就是坏的**：旧版 `fake08` 在 RA 里直接 SIGILL、根本加载不了；新版正常，等于顺带修好。
- 新增 `/usr/local/sbin/ngp-core-update.sh`（`3ec2277a5e5e…`）：plan / check / install / raload / verify /
  compare / rollback，`--32` 切 32 位目录；刷出来的卡和现役卡用同一个入口继续更新。
- 新增 `/usr/local/share/ngp-cores/manifest-20261015.txt`：这次换掉的 48 个内核的名字与 md5。
- 内核源码有了真正的仓库：4 处改动是 **`llj503/kernel_rk3562` 分支 `ngp45ht`**（`56dced3ff`，父提交
  `557e5c28a`）上的 4 个正式提交，`_repo` 的子模块已指向它（`git submodule update --init kernel_rk3562` 直接拿到
  打好补丁的内核）；`kernel-patches/*.patch` 由 `git diff 557e5c28a..HEAD` 重新生成，两者内容一致（用
  `git apply --check --reverse` 四个补丁逐一验证过）。

**没有变化的东西**：RetroArch 仍是 1.22.2 —— 这就是上游最新 release，也是基线 pin 的版本，再往上只有 nightly，
代价是所有内核 ABI 连坐；PPSSPP v1.20.4 同理；卡上的 MAME 内核已经是 0.281。

### 下载与校验

发布地址：<https://github.com/llj503/dArkOS_ngp45ht/releases/tag/ngp45ht-20261015>
（三卷 + `sha256sums.txt` + 整包 `.sha256` 都在附件里；GitHub 对每个附件回出的 sha256 digest
与本地文件逐一核对一致，三卷大小相加 = 4,502,192,424 B = 整包大小。）

GitHub 的 release 单文件上限是 2 GiB，所以整包按 1.9 GB 切了三卷：

| 文件 | 大小 | sha256 |
|---|---|---|
| `dArkOS_ngp45ht_trixie_20261015-00.img.xz.part` | 1,992,294,400 | `437a2333ad3634663e62ed9bf09ba4de412ca66e2c50cef72a4f5f4e2f7c21ae` |
| `dArkOS_ngp45ht_trixie_20261015-01.img.xz.part` | 1,992,294,400 | `18b35707d5ff99622c019e1190c3ed72d19cc9534a86fabfdf35f291517df559` |
| `dArkOS_ngp45ht_trixie_20261015-02.img.xz.part` | 517,603,624 | `5bc25341b94fe85c4dbe7dd4bf035694f8f169144d33fd901c9bf2cdaefa147f` |

合并后整包 `dArkOS_ngp45ht_trixie_20261015.img.xz` = 4,502,192,424 B，
sha256 `a0f7c41af3f3cfe988a35cf3634e12aebbe48b2c0687b68da841409eb9b4e67f`，解压后 12 GiB（12,884,901,888 B）。
三卷拼接后 `xz -t` 通过，所以切分无损。

```bash
cat dArkOS_ngp45ht_trixie_20261015-*.img.xz.part > dArkOS_ngp45ht_trixie_20261015.img.xz
echo "a0f7c41af3f3cfe988a35cf3634e12aebbe48b2c0687b68da841409eb9b4e67f  dArkOS_ngp45ht_trixie_20261015.img.xz" | sha256sum -c -
xz -dc dArkOS_ngp45ht_trixie_20261015.img.xz | sudo dd of=/dev/<TF卡> bs=4M status=progress
```
Windows 下用 7-Zip 解出 `.img` 再交给 Rufus（"DD 模式"写入）。首次开机 `/boot/firstboot.sh` 会跑一次：
PPSSPP 输出改 SPK、RetroArch 的 L2/R2 按按钮绑定、删除底包自带的 SSH 主机密钥并重生成、替换 hostapd 默认热点口令。

## 2026-10-13 · `dArkOS_ngp45ht_trixie_20261013.img.xz`

第一版可刷镜像，由 RG43H 底包组装：本板自己的 `RKNS` idbloader + 打过充电参数的原厂 U-Boot、新写的
`rk3562-ngp45ht.dts`、重编的 `Image`、匹配的两个 AIC8800DC `.ko`。整包 sha256 `2ac34998…`，
`Image 4216e224…`、`dtb f716f307…`、`firstboot.sh 8c1a37e6…`。

修的问题：摇杆通道顺序与 X 极性（`ch5=LX/ch4=LY/ch7=RX/ch6=RY`）、MODE/X/Y/L1/L2/R1/R2 七键与 TF2 卡槽同时失效
（根因是 RK817 LDO_REG8 这条 IO 轨没上电）、PPSSPP 的 L2/R2（SDL 只认 `ABS_Z/ABS_RZ`）、PPSSPP 无声
（`ppsspp.sh` 强制 `Playback Path HP`，本板喇叭在 RK817 的 SPK 上）、WiFi（AIC8800DC 是 USB 设备，且精简内核的
Image 必须和重编的 `.ko` 同源）。
