# XIFAN NGP45HT 移植（dArkOS on RK3562）

XIFAN NGP45HT 是一款 **Rockchip RK3562** 掌机：2 GB RAM、3.7 GB eMMC、1024×768 原生横屏 DSI
面板、双摇杆（SARADC1）+ 17 个 GPIO 按键、双 TF 卡槽、USB 总线的 **AIC8800DC** WiFi。
它的 SoC、RK817 PMIC 和面板初始化序列与 [AISLPC RG43H Pro](../README.md) 逐字节相同，
因此本移植是在 RG43H target 旁边新增一块板子的 DTB / defconfig / 输入驱动，而不是新平台 bring-up。

原厂系统是 EmuELEC（vendor `micro-gamepad` 驱动 + `rk3562-evb1-lp4x-v10-linux` DTB），dArkOS 的
5.10 BSP 里没有那个驱动，所以按键和摇杆全部由本仓库的 `rk3562-joystick.c` + 自建
`rk3562-ngp45ht.dts` 承担。

## 目录结构

| 路径 | 内容 |
|------|------|
| `kernel-patches/` | 4 个内核补丁（摇杆驱动、板级 DTS + DTS Makefile、`ngp45ht_defconfig`、共享 dtsi 的 phandle 标签）+ `apply.sh` |
| `kernel-patches/apply.sh` | 只 `git apply`，全部先 `--check`；`--revert` 撤销。不会动 tree 里其他文件 |
| `tools/dts/` | `rk3562-ngp45ht.dts`（权威源）、`rk3562-ngp45ht.dts.tpl`（模板）、`ngp45ht_defconfig` |
| `tools/slimbuild.sh` | **复现出厂内核**：`ngp45ht_defconfig` 的 Image + DTB + 两个 AIC8800DC `.ko` |
| `tools/imgbuild.sh` | 只重编 DTB / 用 `rg43h_defconfig` 增量重编 Image（历史路径，见下） |
| `tools/dtbrebuild.sh` | 单编 DTB 并打印解析后的 joystick 节点，改 key/轴时最快 |
| `tools/fatpatch.py` | 直接在 `.img` 的 FAT boot 分区里 list/patch/extract 文件（不重刷卡） |
| `tools/install_wifi.sh` | 把 AIC8800DC 的 `.ko` + `/usr/lib/firmware/aic8800DC` + softdep/modprobe 装进 rootfs 镜像 |
| `tools/ngp-core-update.sh` | **设备侧** libretro 内核更新器：plan / check / install / verify / compare / rollback（`--32` 换 32 位目录） |
| `tools/ngp-shaders.sh` | **设备侧**遮罩/滤镜：install / install_masks / masks on·off·status·list / percore / apply / overlay / measure / verify / repair / status（详见上面「遮罩与滤镜」） |
| `tools/ngp-bt-agent.py` `tools/ngp-bt-agent.service` `tools/install_bt_agent.sh` | BlueZ 配对应答 agent（auto-accept，`RequestPinCode` 回 `0000`）与它的 systemd 安装器 |
| `tools/ngp-bt-pair.sh` `tools/btpair.sh` `tools/btdump.sh` | 配对 CLI、扫描+自动挑目标配对、广播/GATT 取证 dump |
| `tools/ngp-panel/` | **屏幕色温/画面调节**（移植自 ROCKNIX `paneladj`）：`panelprop.py`（ctypes 写 DRM 连接器属性，无需 sudo/modetest）、`paneladj.sh`（CLI）、`屏幕色温.sh`（ES 系统菜单中文前端）、`ngp-panel-restore.service`（开机重放）、`install.sh`（镜像/卡片两用）、`mkpsf.py` + `Unifont-CJK-panel.psf.gz`（512 字形位中文控制台字体）。详见 `tools/ngp-panel/README.md` |
| `tools/ngp-bootspeed-fix.sh` `tools/zram-swap.service` | **设备侧**启动速度修复：干掉 fstab 里指向不存在分区的 swap 行（每次开机白等 `DefaultDeviceTimeoutSec` 90 秒），改用 zram；`--check` 只报告不改。幂等，20261017 及更早的镜像刷出来都能原地修（1m41.6s → 12.7s，实测 A/B 见 CHANGELOG） |
| `tools/ngp-ssh-always-on.sh` | **设备侧**把 SSH 设成开机自启并立刻拉起（`--check` 只看不改）。上游 `/opt/system/Enable Remote Services.sh` 只做 `systemctl start ssh.service`，它那行 `systemctl enable ssh` 是**注释掉的**，于是每次重启 SSH 都消失、要手动去 Options 里再开一次。新卡由 `/boot/firstboot.sh` 自动处理，已装机的卡跑这个即可。**注意**：`/usr/local/bin/auto_suspend.py` 默认空闲 **30 分钟**就 `systemctl suspend`（充电时不计），睡着的机器当然不回应 SSH，超时值在 `/home/ark/.config/.TIMEOUT` |
| `tools/ngp-rompool.sh` | **设备侧**双 TF 卡合成一个 `/roms`（mergerfs）+ `/roms2` 与 `/opt/system/Tools` 绑定挂载 + 池挂了时兜底直接挂 TF1 |
| `tools/img-slice.py` `tools/img-compare.py` `tools/img-verify.py` | **从实机卡克隆镜像**的三件套：从上一版镜像切出读不到的片段（p1/p2 bootloader + GPT、p3 尾部 slack、尾部 p5 + 备份 GPT）、新旧镜像**逐区域**对比、镜像结构校验（GPT 两个 CRC32 都用独立实现重算、btrfs `total_bytes` 与分区尺寸比对）。**坑**：p3 的 slack 在 `PREFIX_END + P3_LEN`（16 MiB + 103,799,808 = 120,577,024），少加一个 `P3_LEN` 就会取到分区**开头**的引导扇区（开头恰好是 `mkfs.fat`，看不出来），静默污染 9,216 字节——逐区域对比才能抓到 |
| `tools/btrfsls.py` | **离线只读**列出 btrfs rootfs 的全部路径：Windows 侧直接读卷或镜像，**不需要挂载**（本机没有 btrfs 驱动、WSL 也被禁用）。rootfs 是 `compress=zstd:1`，小文件（NetworkManager 连接配置、`.VERSION`）躺在压缩 extent 里，**对镜像做明文 grep 是假阴性**——20261017 镜像就是这么把两个家用 WiFi 的 psk 漏进公开发布包的。文件名存在 B 树叶子、元数据从不压缩，所以扫叶子是可信的：`python btrfsls.py '\\.\Volume{GUID}' --grep nmconnection`，镜像加分区偏移 `python btrfsls.py img 121634816`。**默认走当前 B 树**（从 root tree 的 ROOT_ITEM 拿到活着的树根再向下遍历）；早期版本是"扫全部物理元数据块"，那会把 COW 换下来、已经变成空闲空间的旧叶子一起读进来，**已删除的文件会复活成幽灵**——曾据此误判 `firstboot.service` 是 enabled、误判 `/etc/fstab` 还有生效的 swap 行。要考古就加 `--sweep`（会明确警告）。另：`--cat PATH` 可取文件内容（含 zstd 解压），`--stat PATH` 取 mtime/size |
| `tools/ngp-xpad-build.sh` | 给 5.10.226 现编 `xpad.ko`（带震动）并安装 + depmod，2.4G XInput 接收器用 |
| `tools/btaic.sh` `tools/btaic2.sh` `tools/btnotify.sh` | 厂商 `aic_btusb` 实验（含强制灌补丁）与 GATT notify/轮询抓取，全部可逆 |
| `tools/devsh.py` | 把本地 `.sh` 推到卡上以 ark 身份执行（顺手去 CRLF），例如 `python devsh.py ngp-core-update.sh plan` |
| `tools/deploy_kernel.py` | 通过 SSH 把 Image + DTB 写到已装机的卡上（带空间检查和哈希校验） |
| `tools/ngpremote.py` `tools/remote_dev.py` | PC 端看屏幕 + 注入按键（1024×768 横屏，PC 只需 Pillow） |
| `tools/*.py` 其余 | 硬件探针：GRF/GPIO/CRU 寄存器、PMIC I²C、按键与 ADC 录制、引脚占用归属 |
| `firstboot.sh` | 只做本板修正的那部分（幂等）；装机卡上是 `/usr/local/sbin/ngp45ht-fixes.sh` |
| `boot-firstboot.sh` | 出厂 `/boot/firstboot.sh` 的逐字节副本 = 上面的修正 **+ dArkOS 自己的 `expandtoexfat.sh` 首启步骤**，别手工跑 |

`tools/` 里保留了调试期的探针脚本，它们记录了每个结论是怎么量出来的；`assemble.sh`、
`kbuild.sh`、`kbuild2.sh` 是过程历史，日常只需要 `slimbuild.sh` / `dtbrebuild.sh` / `fatpatch.py`。
脚本顶部的 `/mnt/f/darkos/...` 是原作者的机器路径，用之前改成自己的。

## 上游同步（mamaich/dArkOS_rg52mini v1.1）

本仓库是 bmdhacks 基线上的 NGP45HT 移植，与上游 mamaich 的 RG52 Mini fork 同源。2026-10-17 合入了
上游 v1.1（`ecb0922`）除 `.gitmodules`、`README.md` 和三个子模块指针外的全部 135 个变更/新增文件——
上游不碰 `ngp45ht/`，所以合入零冲突。本仓库的差异只有三处：

| 文件 | 处理 |
|---|---|
| `.gitmodules` / 三个子模块指针 | 保留本仓库版本：`kernel_rk3562` 指向 `llj503/kernel_rk3562` 的 `ngp45ht` 分支（我们的 DTS + 摇杆/触发器驱动补丁在里面） |
| `finishing_touches-rk3562.sh` | panel-kick 只装 rg52mini（它的 rev-A 判定对没有 husb311 的设备恒真，NGP45HT 会白翻一次屏）；OTA 安装与 `/etc/darkos-release` 扩展到 `ngp45ht`；新增 NGP45HT 的面板组件安装块 |
| `scripts/rk3562/darkos-ota` | 默认 feed 改指本仓库的 `ota/ngp45ht.json`（空 feed 起步；`DEVICE` 决定用哪份） |

上游带来、本机直接受益的：`perfmax`/`perfnorm` 改为探测 GPU devfreq 节点（写死 `fde60000` 的问题已修）、
内核模块 `--strip-debug`（`.ko` 约省 97%，p4 空间紧张下的实质缓解）、PortMaster E2BIG 修复、睡眠/电源键
修复三件套（sleep hook + `pause.sh` + ES sleep/wake 脚本 + 背光记忆 udev 规则）、根目录归属修复、
Wifi.sh 的 rk3562 开关、bttoggle 持久化、RetroArch 安全补丁 0021-0023。

## 构建

WiFi 驱动不在仓库里（厂商源码，GPL 混编），先克隆：

```bash
git clone https://github.com/AveyondFly/aic8800-usb /root/ngp/aic8800-usb
```

内核编译在 WSL 里进行，构建树是 root 所有的 ext4 副本（`/root/ngp/kernel_rk3562`），
源码树在 Windows 侧。从本仓库根目录：

```bash
bash ngp45ht/kernel-patches/apply.sh kernel_rk3562        # 打补丁
wsl -u root bash -lc "bash /mnt/<x>/ngp45ht/tools/slimbuild.sh"
```

同一批改动也整理成了 4 个正式提交，放在 **[llj503/kernel_rk3562 的 `ngp45ht` 分支](https://github.com/llj503/kernel_rk3562/tree/ngp45ht)**
（`56dced3ff`，父提交就是 bmdhacks 的 `557e5c28a`）；仓库的子模块已经改指向这个分支，
`git submodule update --init kernel_rk3562` 拿到的就是打好补丁的内核。`kernel-patches/` 是同一内容的可移植形式，
由 `git diff 557e5c28a..HEAD` 重新生成，所以分支和补丁系列两者不会走偏。

`slimbuild.sh` 会把 5 个改动文件重新拷进构建树、跑 `make ngp45ht_defconfig`、编
`Image modules dtbs`，再单独用内核树驱动外部模块编译（驱动自己的 Makefile 硬编码了厂商 `KDIR`），
最后把 `Image-ngp45ht`、`rk3562-ngp45ht.dtb` 和两个 `.ko` 连同 sha256 一起 stage 出来。
实测复现结果：DTB 和两个 `.ko` 与出厂镜像逐字节一致，Image 大小一致、只有内嵌的 build tag 不同
（要字节级复现请设 `KBUILD_BUILD_TIMESTAMP`）。

注意：**Windows 写的 `.sh` 必须先 `sed -i 's/\r$//'`**，且 `wsl ... bash -lc '...'` 的外层 bash 会先展开
`$VAR` 和 `$( )`，所以命令行里只用字面路径。

## Image 与 out-of-tree 模块必须一起走

`CONFIG_MODVERSIONS` 是关的，而两个 config 的 vermagic 完全相同（`5.10.226 SMP mod_unload aarch64`），
所以拿 `rg43h_defconfig` 编出来的 `aic8800_fdrv_usb.ko` 也能塞进 slim Image 里，加载不报错，
只是 WiFi 永远 association 失败——这就是当初"精简 config 杀网络"的真凶。两个 `.ko` 与 Image 同源，
才有网络。装完记得在 rootfs 里重跑 `depmod`。

## libretro 内核（cores）更新

dArkOS 不编内核：`build_retroarch.sh:98` 在构建镜像时从 `christianhaitian/retroarch-cores` 的 **rg503** 分支
wget 每个 `<core>_libretro.so.zip`（只有 rk3326 用 master），所以卡上的内核就是镜像那天那个分支的样子。
每个内核的构建日期写在分支自带的 `aarch64/.index-extended` 里，不下载就能判断谁落后。

RetroArch 本体没什么可升：卡上是 `1.22.2 (Jun 3 2026)`，而 v1.22.2 就是上游最新 release、也是
`rk3562_core_builds/scripts/retroarch.sh` 里 `tag=` pin 的版本；PPSSPP 的 v1.20.4 同理也是最新 release。
再往上只有 nightly，代价是所有内核 ABI 连坐。

2026-10-15 实测：卡上 130 个内核（129 个来自 `retroarch_cores.txt`，`mametiger` 两个分支都不发布，只能留在
镜像里的版本），镜像之后被重建过 52 个，其中 49 个字节确实不同，已全部装上并逐个 md5 校验；
`arduous`/`chimerasnes`/`minivmac` 只是重建、字节相同。**卡上的 MAME 内核已经是 0.281。**

必须跑在**设备侧**：这台 PC 拉 `raw.githubusercontent.com` 只有约 11 KB/s，而同一张卡自己是约 6 MB/s
（19 MB 三秒下完）；`build_retroarch.sh` 用的 `github.com/.../raw` 形式在 PC 上会重定向到
`media.githubusercontent.com` 直接卡死。

```bash
python devsh.py ngp-core-update.sh plan                # 只看 .index-extended，谁落后
python devsh.py ngp-core-update.sh check <core> ...     # 下载并比对字节
python devsh.py ngp-core-update.sh install <core> ...   # 备份后替换 + md5 + RA 加载验收，打不开自动回滚
python devsh.py ngp-core-update.sh raload <core> ...    # 权威验收：让 RetroArch 自己加载每个内核
python devsh.py ngp-core-update.sh compare              # 与备份做差分 dlopen（advisory）
```
刷了 20261015 镜像的卡不用从 PC 走：工具就在 `/usr/local/sbin/ngp-core-update.sh`，
`sudo /usr/local/sbin/ngp-core-update.sh plan` 直接可用（`devsh.py` 只是把它推上去再跑）。

验收要看 **`raload`**。它让 RetroArch 自己去 dlopen 每个内核，跑在临时 `HOME=/tmp/rahome` 里，
`video_driver`/`audio_driver`/`input_driver` 全设 `null` 且 `save_config_on_exit = "disabled"`，所以既不写你现在的
`retroarch.cfg`，也不抢面板的 DRM；内核加载成功后会自己打横幅（fbneo 是 `[FBNeo] Running v1.0.0.03 260904
GITa251c7622`），而 `requires content, but nothing was provided` 这句就是"加载成功"。
`verify`/`compare` 用裸 ctypes dlopen，只能当参考：RetroArch 自己的进程已经带了 libstdc++、libiconv 这些依赖，
所以 `mame`/`ppsspp`/`stella`/`easyrpg`/`vircon32`/`dosbox_pure`/`hatarib`/`emuscv`/`mess` 九颗明明正常的内核会被
报 undefined symbol —— 我就因此**误回滚过一次** `DoubleCherryGB`（它其实加载得好好的，后来按 RA 验收重新装上了）。
真正不行的是 `np2kai`：新版能装、md5 也对，但 RetroArch 直接 `Failed to open libretro core`（缺
`ymzadpcm_getpcm`），所以它保持镜像里的旧版。`install` 现在每装一颗就用这套 RA 探测验收，打不开就自动恢复刚备份的
旧版 —— "更新"不等于"能加载"。同一次扫描还发现**旧版 `fake08` 本身就是 SIGILL（rc=132）、从来加载不了**，新版才
正常；每个内核单独起进程就是为了让它只杀自己、不掩盖元凶。最终：48 颗升级并通过 RA 加载测试，`np2kai` 保留旧版。

备份目录默认 `/roms/core-backups/<日期>-64`：根分区只剩 5.8 GB，而 `mame_libretro.so` 单文件就 200 MB。

## 遮罩与滤镜

借鉴 ROCKNIX 的遮罩/滤镜体系，但**只搬对我们这台有效的部分**。ROCKNIX 的做法是两支包 + overlayfs：
`tmp-shaders.mount` 把 `common-shaders`(Cg) + `glsl-shaders` + `slang-shaders` 叠成 `/tmp/shaders`
（upper 是 `/storage/shaders`），`tmp-overlays.mount` 把 `retroarch-overlays` 叠成 `/tmp/overlays`。

钉死的版本（都按 sha256 校验过，卡上直连 codeload 实测 7.6 MB/s）：

| 包 | commit | sha256 | 装进来的是什么 |
|---|---|---|---|
| `libretro/slang-shaders` | `a2ac00bc` | `5ae2a62c…` | **1822 个 `.slangp` + 1355 个预编译 `.slang`** → `/opt/ngp-shaders/shaders/shaders_slang` |
| `libretro/common-overlays` | `ea3f2bf1` | `4025f261…` | 83 个遮罩 `cfg` + 153 个 PNG（只取 `borders ctr effects misc`）→ `/opt/ngp-shaders/overlays` |

**素材必须放 `/opt`，不能放 `/roms`。** dArkOS 的 `Switch to SD2 for Roms.sh` / `Switch to Main SD for Roms.sh`
会对 `retroarch.cfg`、`retroarch32/retroarch.cfg` 等文件做全局字符串替换
（`sed -i '/roms2/s//roms/g'` 及其反向），所以我写在 `retroarch.cfg` 里的 `video_shader = "/roms/shaders/…"`
被改成 `/roms2/shaders/…`，而 TF2 上没有这个目录，叠加 `video_shader_enable = "true"`，**RA 加载内容时直接退出**
（表现就是"切换到 TF2 后游戏闪退"）。`/opt` 在系统卡的 btrfs 上、永不参与该替换。实测验证：把两个方向的
sed 都跑在配置副本上之后，`retroarch.cfg` **逐字节不变**。

**这台机器上有效的滤镜后端是 `glslp`，不是 slang** —— 原因见下面「64 位 RetroArch 打不开」一节：
底包把 64 位 RA 配成 `video_driver = "vulkan"`，而本机的 Vulkan 无法创建显示表面，已改回 `gl`。
`.slangp` 需要 Vulkan，所以那一整套暂时用不上（文件保留，等 vulkan 修好可用）；
`common-shaders`/`retropie-shaders` 那两层是 **Cg**，RA 1.22 已不支持，根本不搬。
底包自带的 630 个 `.glslp` 是现在能用的那套，`/opt/ngp-shaders/shaders/shaders_glsl` 是指向
`~/.config/retroarch/shaders/shaders_glsl` 的符号链接（`/opt` 在 btrfs 上，可以有软链）。

**遮罩和分辨率的坑（决定了两类东西不能混用）**：`common-overlays` 里多数遮罩写的是
`overlay0_full_screen = true`（如 `effects/patterns/grid.cfg`、`ctr/effects/scanlines-alpha.cfg`），
PNG 是**按屏幕铺**的；本机 1024×768 而绝大多数主机的画面不满屏，固定 PNG 遮罩必然和游戏像素错位。
只有 `effects/scanlines/aperture-grille-3x.cfg` 是 `full_screen = false`。
所以**像素对齐的遮罩交给 shader**（`handheld/lcd-grid-v2`、`crt/crt-aperture`、Mega Bezel 的 `__LCD-GRID` 系列），
PNG 包只当边框/装饰用。

工具：`tools/ngp-shaders.sh`

```sh
./ngp-shaders.sh install                 # 下载 + sha256 校验 + 解包 + 改 cfg
./ngp-shaders.sh percore lcd gba gb      # 只给 GBA/GB 上 LCD 网格遮罩，其它系统一律不动
./ngp-shaders.sh percore off arcade      # 显式给街机关掉 shader（比依赖全局关更保险）
./ngp-shaders.sh verify mgba             # 无头跑一次 RA，用日志证明 override 真被读到
./ngp-shaders.sh apply lcd               # 全局预设（街机会跟着生效，一般不用）
./ngp-shaders.sh overlay grid            # PNG 边框/遮罩（注意上面的 full_screen 限制）
./ngp-shaders.sh measure on|off          # 屏上 fps（fps_show），用来判某档能不能吃满帧
./ngp-shaders.sh off                     # 全屏蔽            list / status 看现状
```

`apply`/`percore` 的档位（`zfast-lcd lcd lcd1 dot lcdshader easymode cgwg aperture geom royale pi hyllian
mbz-potato mbz-std`）路径全部在钉版本 tarball 里逐条核实过存在，不写没验证过的文件名。`percore` 会同时处理
两套 RA（64 位 `~/.config/retroarch` 与 32 位 `~/.config/retroarch32`），只给该树里**真的装了的核心**写文件，
按驱动选 `.glslp` 还是 `.slangp`。安装只往 `retroarch.cfg` 里改 4 个键（`video_shader_dir` /
`video_overlay_dir` / `video_shader` / `video_shader_enable`），第一次运行会备份成 `retroarch.cfg.bak-shaders`。

### per-core 遮罩：RA 只认 `config/<核心名>/<核心名>.cfg`

`configuration.c` 的 `config_load_override()` 拼出来的 per-core 路径只有一种形态：

```
<config_directory>/<library_name>/<library_name>.cfg
```

`config_directory` 取自 cfg 里的 **`rgui_config_directory`** 键（键名不是 `config_directory`；
`file_path_special.c` 的 `APPLICATION_SPECIAL_DIRECTORY_CONFIG` 分支只在它为空时才退化成"主 cfg 所在目录"），
本机是 `~/.config/retroarch/config`。`library_name` 来自核心的 `retro_get_system_info()`，与 `.info` 里的
`corename` 一致——`mgba` 和 `mgba_rumble` 都报 `mGBA`，所以一个文件同时覆盖两个核心（ES 的 gba 默认核就是
`mgba_rumble`）。

**扁平的 `config/mGBA.cfg` 连 stat 都不会被 stat**，而第一版正是这么写的，症状就是"遮罩装了、GBA 打开却没有、
得手动切一次"。改对之后卡上实测（无头、null 驱动、`--max-frames 3`）：

```
[INFO] [Override] Core-specific overrides found at "/home/ark/.config/retroarch/config/mGBA/mGBA.cfg".
[INFO] [Config] Appending override config: ".../config/mGBA/mGBA.cfg".
```

核心名带空格同样成立（`FinalBurn Neo/FinalBurn Neo.cfg`、`MAME 2003-Plus/…`）。`verify` 子命令就是把这段探针
固化下来，`percore` 也会顺手删掉旧布局留下的扁平文件（`status` 会把它们标成 `!! stale flat file`）。

### RA 退出时会把整份 cfg 重写一遍

`config_save_on_exit = "true"`（dArkOS 默认）意味着 RA 进程退出时**用内存里的设置覆盖 `retroarch.cfg` 全文**。
两个后果都在这台机器上实测到过：

- **RA 运行期间从外部改 cfg，改动会被悄悄还原。** `core_updater_buildbot_cores_url` 就是这样从官方 buildbot
  变回 `christianhaitian/retroarch-cores/rg503/aarch64/` 的。改 RA 配置前先
  `pgrep -f '/opt/retroarch/bin/retroarch'`，确认它没在跑。
- **`--appendconfig` 里的值也会被写进真实 cfg。** 用 `-c 真实cfg` + 内含 `video_driver="null"` 的 appendconfig
  做无头探针，一次就把卡写成 `video_driver/audio_driver/input_driver/menu_driver = "null"`，再进游戏就是黑屏。
  正确值取自 `retroarch.cfg.bak-shaders`：`gl` / `alsathread` / `udev` / `glui`；`verify` 现在一律对 cfg 的
  **副本**跑 RA，并在结束后比对 md5，被动过就从快照还原。

### 和 ROCKNIX（AveyondFly）的做法对比：为什么没照搬

`AveyondFly/distribution_rocknix`（分支 `next`）的遮罩**不走 RA 的 per-core override**，而是在启动链里现算：

| 环节 | 文件 | 做什么 |
|---|---|---|
| 选 | `packages/ui/emulationstation/config/common/es_features.cfg` + `rocknix/sources/scripts/getshaders` | ES 里每个系统一个 `shaderset` 选项，取值由 `find /tmp/shaders -regex '.*\.\(glslp\|slangp\)$'` 列出 |
| 算 | `rocknix/sources/scripts/setsettings.sh` 的 `set_shader()` | 读 `game_setting shaderset`，往 `TMP_CONFIG=/tmp/.retroarch.cfg` 追加 `video_shader_enable="true"` / `video_shader="<相对 /tmp/shaders 的路径>"`，同时 `echo -n " --set-shader /tmp/shaders/$SHADER"` |
| 跑 | `rocknix/sources/scripts/runemu.sh` | 把上面的 stdout 拼进命令行：`retroarch -L /tmp/cores/$CORE_libretro.so --set-shader … --config …/retroarch.cfg --appendconfig /tmp/.retroarch.cfg "$ROM"` |

它能成立的前提是**有一层自己的启动器**（`emu` → `runemu.sh` → `setsettings.sh`）加上只读的 `/tmp/shaders`
overlayfs 挂载。dArkOS 两样都没有：ES 的命令是写死的

```
sudo perfmax %GOVERNOR% %ROM%; nice -n -19 /usr/local/bin/%EMULATOR% \
  -L /home/ark/.config/%EMULATOR%/cores/%CORE%_libretro.so %ROM%; sudo perfnorm
```

`/usr/local/bin/retroarch` 只是 netplay/dialog 包装（真正 exec 的是
`/opt/retroarch/bin/retroarch -c /home/ark/.config/<emulator>/retroarch.cfg`）。要塞 `--appendconfig` 就得改
`es_systems.cfg` 或那个包装脚本，并且每个系统维护一份临时 cfg；RA 原生的 per-core override 不动启动链就能达到
同样效果，所以这里只搬 ROCKNIX 的**素材包**，机制用自己的。

### 768P PNG 遮罩：按游戏分类自动加载

这类包（用户给的 `66的768p遮罩-通用`，18 组）是 **1024×768 全屏 PNG**，中间挖一个透明窗口，配套 `cfg` 只有四行：
`overlays = 1` / `overlay0_overlay = X.png` / `overlay0_full_screen = true` / `overlay0_descs = 0`。
窗口不是随便画的，而是**各自分辨率的整数倍**，所以只要开整数缩放就严丝合缝（下表是按 PNG 的 alpha 通道量出来的）：

| `/roms` 目录 | 遮罩 | 窗口 `x,y W×H` | 整数倍 |
|---|---|---|---|
| `gba` | `GBA_768P_Grid` | 32,64 960×640 | 240×160 ×4 |
| `gb` / `gbc` | `GB_768P_SHADER_DMG` / `GBC_768P_Grid` | 112,24 800×720 | 160×144 ×5 |
| `nes` / `famicom` / `fds` | `NES_8-7_768P` / `FC_8-7_768P` | 128,48 768×672 | 256×224 ×3 |
| `snes` / `sfc` | `SNES_8-7_768P` / `SFC_8-7_768P` | 128,48 768×672 | 256×224 ×3 |
| `megadrive` / `genesis` | `MD_768P` | 32,48 960×672 | 320×224 ×3 |
| `wonderswan(color)` | `WSC_768P` | 64,96 896×576 | 224×144 ×4 |
| `pico-8` | `PICO_768P` | 128,0 768×768 | 128×128 ×6 |
| `ngp` / `ngpc` | `NGPC_768P` | 121,23 782×741 | 160×152 ×≈4.9，**唯一对不齐的**（差约 2%） |

所以每条 override 写的是 `video_scale_integer = "true"` + `input_overlay*`，并且 `video_shader_enable = "false"`
——`*_Grid` 版本自带半透明网格（窗口内平均 alpha 62/255，不带 Grid 的是 0），再叠 glsl 的 `lcd-grid-v2` 就重复了；
想用 shader 就把那一行删掉。`install_masks` 会逐个校验 cfg 指向的 PNG 存在、且 IHDR 真的是 1024×768
（用 `dd`+`od` 读，不依赖 python/PIL），因为 `full_screen = true` 会把尺寸不对的图拉伸。

**"按分类"走的是 RA 的 per-content-directory override，不是 per-core**：`config_load_override()` 还会拼
`<config_dir>/<library_name>/<ROM 的父目录名>.cfg`，并且**叠在 per-core 之上**（源码里 core → content-dir → game
依次 append，后者胜）。这正好解决"GB 和 GBC 共用一个 Gambatte"的问题：`config/Gambatte/gb.cfg` 与
`config/Gambatte/gbc.cfg` 各写各的遮罩。卡上实测三层都在：

```
[Override] Core-specific overrides found at ".../config/mGBA/mGBA.cfg".
[Override] Content dir-specific overrides found at ".../config/mGBA/gba.cfg".
[Override] Content dir-specific overrides stacking on top of previous overrides.
```

素材**不进仓库**（第三方美术、来源不明），装法：包放到卡上，然后
`ngp-shaders.sh install_masks /home/ark/masks768.tar.gz` + `masks on`；换某一张用 `masks gba GBA_768P`
（选择记在 `/opt/ngp-shaders/masks.conf`，`masks on` 会照着复现）。

### ES 里看不到 FBNeo：系统表里根本没有这一项

`/etc/emulationstation/es_systems.cfg` 有 130 个系统，街机类只有 `arcade`(→`/roms/arcade`)、`cps1/2/3`、
`neogeo`(→`/roms/neogeo`)、`mame2003/2010`；而那 2020 个 FBNeo 游戏在 **`/roms/fbneo`**，没有任何系统指向它。
ES 只列出**有内容的系统**，所以前端只剩 CPS1 / GBA / ports（`/roms/pico-8` 那 3 个文件同理，也没有系统项）。
修法是在 `arcade` 之前插一个 `fbneo` 系统块：`<theme>arcade</theme>` 复用现役主题（`es-theme-nes-box`，198 个目录，
有 `arcade` 但没有 `fbneo`）的美术，核心只列**真装了的**（`fbneo hbmame fbalpha2012 mame2003_plus mame`；
底包 `arcade` 块里那个 `km_fbneo_xtreme_amped` 卡上并不存在）。改完 `systemctl restart emulationstation`
（ES 是 `emulationstation.service`，重启即重扫，不用重启整机）。两个注意点：落盘前先
`ET.fromstring()` 解析一遍——`es_systems.cfg` 语法错了 ES 会**一个系统都不显示**；原文件备份成
`es_systems.cfg.orig-ngp`。

两个 Windows/exFAT 特有的坑记在这：**exFAT 不能存符号链接**，所以两套 shader 是复制而非软链；
**`tar` 在 exFAT 上必须加 `--no-same-owner`**，否则还原归档里的 root 属主会一路报
`Cannot change ownership … Operation not permitted` 并以非零退出。

**没进 20261015 镜像**：素材约 165 MB，而镜像里 p4 只剩 224 MB、p5 也只是底包大小（首次开机才扩到整卡）。
所以这一步交给使用者在卡上跑一次 `install`（下载约 70 MB 压缩包），镜像本身不动。

## 64 位 RetroArch 打不开（黑屏一闪）

排查顺序记下来，因为这条链上有三个独立陷阱，每个都可能让人误判：

1. **入口不是 RA 本体**。ES 的系统项是 `<name>retroarch</name> <path>/opt/cmds/</path>`
   `<command>sudo perfmax %GOVERNOR% %ROM%; %ROM%; sudo perfnorm</command>`，`%ROM%` 展开成
   `/opt/cmds/retroarch.sh`，它再调 `/usr/local/bin/retroarch`（3.1 KB 的 **dialog 控制台包装脚本**，
   会 `chmod 666 /dev/tty0`、`printf "\033c" > /dev/tty0`、`dialog --clear`、`buttonmon.sh Test_Button_X`），
   最后才 exec `/opt/retroarch/bin/retroarch -c ~/.config/retroarch/retroarch.cfg`（16 MB 的 ELF）。
   所以从 SSH 直接跑那个包装脚本必然出现 `Error opening terminal: unknown.`，那是噪声不是故障；
   另外 `perfmax` **不会 exec 它的第 2 个参数**，它只设 governor，所以看到 `perfmax` 的 sudo 记录
   并不代表 RA 已经启动。
2. **拿到真实报错的办法**：不要动二进制。把 `/opt/cmds/retroarch.sh` 包一层 tee
   （备份成 `/opt/cmds/retroarch.sh.orig-ngp`），就能记下 `tty`/`TERM`/退出码；再配合 RA 自己的
   `log_file` + `log_path`（写在 tmpfs）。本机取到的是：

   ```
   [INFO] [Vulkan] Found GPU at index 0: "Mali-G52".
   [ERROR] [Vulkan] Failed to create KHR_display surface.
   [ERROR] [Video] Cannot open threaded video driver. Exiting...   → rc=1
   ```
3. **根因**：GPU 是 **Mali-G52**，Vulkan ICD 是 `/usr/lib/aarch64-linux-gnu/libmali-bifrost-g52-g29p1.so`
   （`rk_vk.json`，`api_version 1.3.276`），设备能枚举，但它自己的 `VK_KHR_display`→DRM 直连路径在这块
   DSI 屏上创建表面失败；而这个 RA build 里 **`SDL_Vulkan_CreateSurface` 出现 0 次**，也就是
   **Vulkan 没有 SDL 上下文可退**，所以没有任何配置值能救它。32 位 RA 之所以正常，是因为它用
   `video_driver = "gl"`（SDL→KMS/DRM→GBM+EGL 这条路在本机是通的，也证明 DRM master 拿得到）。
   **修法就是把 64 位也改成 `gl`**：`video_driver = "gl"`、`menu_driver = "glui"`，之后两套配置的差别只剩位数。
   副作用是遮罩只能用 `.glslp`（上一节）。

顺带量到两个上游缺陷，不是本次故障的原因但值得记：

- `perfmax` / `perfnorm` 把 GPU 地址写死成 **`fde60000`**（RK3566/3568 的位置），本机 Mali 在
  **`ff320000`**，所以每次启动都刷 `…/fde60000.gpu/devfreq/…/governor: No such file or directory`，
  **GPU 频率/调速实际上从没被设过**；脚本没有 `set -e` 也不 `exit`，所以只是无效而非致命。
- 切卡脚本反复 `mount` 而不 `umount`，我在 `/proc/mounts` 里数到 **`/roms` 被叠挂 4 次**；
  清理办法是循环 `umount -l /roms` 到只剩一个再 `mount -o remount`。

## 两张 TF 卡合并成一个 /roms（mergerfs）

需求是"不用切卡就能看到两张卡的游戏"。**内核 overlayfs 在这台机器上做不到**，实测四种组合全部被拒，
内核原话是 `overlayfs: filesystem on '<path>' not supported`（连 btrfs+vfat 也拒），因为 overlayfs 要求每层
文件系统支持 exportfs，FAT/exFAT 不支持；`CONFIG_OVERLAY_FS=y` 也没用。Batocera 走的是 **mergerfs（FUSE 联合）**，
它的 `batocera-storage-manager` 里就是 `POOL_PATH=/userdata/roms` + `mergerfs $OPTS "$BRANCHES" "$POOL_PATH"`，
这条路我们照搬并且验证通过。

布局（`tools/ngp-rompool.sh install|merge|status|revert`）：

| 挂载点 | 内容 |
|---|---|
| `/mnt/roms1` | TF1 exFAT（`mmcblk1p5`，系统卡的 ROM 分区） |
| `/mnt/roms2` | TF2 vfat（`mmcblk2p1`），`nofail`，**不在也没关系** |
| `/roms` | `fuse.mergerfs` 联合，**所有 dArkOS 路径不用改** |
| `/roms2` | TF2 分支的 bind，老脚本仍能找到 |
| `/opt/system/Tools` | 从池里 bind |

mergerfs 选项：`allow_other,use_ino,inodecalc=path-hash,category.create=epff,func.getattr=ff,`
`cache.files=partial,dropcacheonclose=true,moveonenospc=true,minfreespace=4G`。
`epff` = 同名目录已存在就写在原卡上，所以**新文件落在 TF1**，同一系统的文件不会被拆到两张卡。

实测（两卡都在位）：`fbneo 2018`(TF1) + `gba 496`/`cps1 53`(TF2) **同时出现在 `/roms`**；递归合并也成立
（TF2 独有的 `bios/nds/usrcheat.dat` 34 MB 通过池可见，`bios/fbneo` 由 79→80）；重启后五个挂载全部由 fstab
自行拉起，`failed units: 0`，保底服务没有触发。开销：`ls -l` 一个 493 条目的目录，直挂 288 ms、池 509 ms
（`func.getattr=ff` 比 `newest` 略快），ES 全量扫描是一次性的；文件读取吞吐看不出差别。

**三个必须记住的坑：**
1. `x-systemd.requires=` 要写**单元名**不是路径。写成 `x-systemd.requires=/mnt/roms1.mount` 时依赖解析不出来，
   加上 `nofail` 就**静默跳过**，`systemctl status roms.mount` 还会因为保底服务挂载了 `/roms` 而显示
   `active (mounted) What: /dev/mmcblk1p5`，非常容易被误判成"已经生效"。正确写法是 `mnt-roms1.mount`。
2. 保底必须有：`ngp-roms-fallback.service`（`ConditionPathIsMountPoint=!/roms`）在池起不来时把 TF1 直接挂到
   `/roms`，保证 ES 永远看得到游戏。第一次重启就是它兜住的。
3. dArkOS 的两支 `Switch to SD2/Main SD for Roms.sh` 会 `mount` 一张卡**盖住**池、并对配置做 `/roms`↔`/roms2`
   全局 sed，所以 `install` 给它们加了守卫（检测到池就拒绝运行，原件备份为 `*.orig-ngp`）。

## GPU 调速从来没生效过（perfmax/perfnorm）

`perfmax`/`perfnorm` 把 GPU 的 devfreq 地址写死成 `fde60000`（RK3566/3568）和 `ff400000`（RK3326），
本机 Mali-G52 在 **`ff320000.gpu`**，于是每次启动只刷
`…/fde60000.gpu/devfreq/…/governor: No such file or directory`，**GPU 频率一直没被抬起来**
（脚本没有 `set -e` 也不 `exit`，所以只是无效而非致命，很容易看漏）。已改成自动探测：

```sh
if [ ! -d "/sys/devices/platform/${gpu}.gpu/devfreq/${gpu}.gpu" ]; then
  _ngp_gpu=$(basename "$(ls -d /sys/class/devfreq/*.gpu | head -1)" .gpu)
  [ -n "$_ngp_gpu" ] && gpu="$_ngp_gpu"
fi
```

改完实测：`perfmax performance` → gpu governor `simple_ondemand → performance`、**cur_freq 300 MHz → 900 MHz**
（本机可选 300/400/…/900 MHz），cpu 与 dmc 同时进 `performance`；`perfnorm` 干净复原成
`simple_ondemand`/300 MHz + `ondemand` + `dmc_ondemand`。备份 `*.orig-ngp`。

## 启动慢：fstab 里指向不存在分区的 swap 行（90 秒 device 超时）

开机要 1 分 41 秒，而 `systemd-analyze blame` 加总只有 ~20 秒的活。这个"对不上"本身就是特征：
**差额是在等一个不存在的设备**，而 device 超时在 `blame` 里看不见（没有 unit 在忙，只是没人往下走）。

```sh
systemd-analyze time            # 4.9s (kernel) + 1min 36.7s (userspace)
systemd-analyze critical-chain  # tmp.mount @1min30.8s  ← 它排在 swap.target 之后
ls /dev/disk/by-partlabel/      # boot dArkOS_Fat emuelec resource rootfs storage uboot —— 没有 swap
grep swap /etc/fstab            # PARTLABEL=swap none swap sw,pri=10 0 0
```

`PARTLABEL=swap` 那行是 rg43h fstab 的照抄（`/dev/zram0` 之外这台机器没有任何 swap 分区），
systemd-fstab-generator 把它变成 `dev-disk-by\x2dpartlabel-swap.device` 塞进 `swap.target`，
于是干等满 `DefaultDeviceTimeoutSec = 90s`。**注释掉它，swap 改由 zram 提供**：

```sh
sudo ngp-bootspeed-fix.sh --check   # 只报告
sudo ngp-bootspeed-fix.sh           # 改（自动备份 fstab、装 zram、修 panel unit）
```

实测 A/B（只差这一行）：1m41.587s → **12.720s**，省 88.9 秒，两轮 `blame` 逐项几乎不动。

两条通用教训：

1. **`Wants=` 一个 device unit 是陷阱**。`After=` 只是排序提示、不建 job，安全；`Wants=` 会让 systemd
   给 device unit 真的建一个 job，设备不来就等到 `DefaultDeviceTimeoutSec`。要等就自己写有上限的
   轮询（`while [ ! -c /dev/dri/card0 ] && [ $i -lt 30 ]; do sleep 0.2; ...`），别把启动交给 systemd 的
   设备超时。
2. **"blame 加总 < userspace 总时长" 就是有人在等 device/mount 超时**，去查 fstab 和 `critical-chain`
   里那个时间戳突然跳了 90 秒的地方，别在 `blame` 里找。

## 板级要点（都是量出来的，不是猜的）





- **RK817 LDO_REG8 决定一切。** 共享 dtsi 把它当 `vcc1v8_dvp` = 1.8 V、无 always-on，而 vendor DTB
  是 3.3 V + `regulator-always-on` + `regulator-boot-on`。这块轨供的是 `GPIO1_C1` 往上（含 `GPIO1_D0..D7`、
  `GPIO2_A`）的 IO pad 域，也就是 **MODE/X/Y/L1/L2/R1/R2 七个按键 + sdmmc1（TF2 卡槽）**。轨关着的
  时候这些 pad 完全不动：软件上 mux/pull/方向/中断/时钟门控和原厂逐字节一样，强行 push 也不变，
  最初很容易误判成"按键表错了"或"5.10 dw_mmc 驱动不了这个槽"。修好之后 `POWER_EN2` 0x07→0x0f，
  空闲 `gpio1 ext_port` 与原厂值 bit-for-bit 相同，`/dev/mmcblk2` 出现。
  **排查顺序：整片 pad 死 ⇒ 先查未上电的 IO 域，把 PMIC 每个 regulator child 的电压与 always-on
  跟 vendor DTB 全量 diff**；这块板上唯一对不上的轨就是它。
- **两个摇杆的 X 都在号更大的通道上**：实测 `ch5=LX, ch4=LY, ch7=RX, ch6=RY`，与 vendor DTB 和
  ROCKNIX 的 `io-channel-names` 相反。两个 X 都需要极性翻转，Y 不需要，所以驱动加了按轴生效的
  `invert-x/-y/-rx/-ry` DT 属性（与原 sysfs 的 `left-stick-invert` 取或；后者必须留着，dArkOS 的
  `Left Stick Invert Toggle.sh` 依赖它）。改了驱动就要重编 Image，只换 DTB 无效。
- **L2/R2 在 PPSSPP 里必须是轴。** SDL 的 GameController 自动映射把 `lefttrigger/righttrigger`
  固定成 `ABS_Z/ABS_RZ`，`BTN_TL2/BTN_TR2`（joydev 索引 6/7）在 controller API 里根本不出现，而这块板
  的肩键是纯 GPIO 开关、没有 SARADC 触发电轴，于是 PPSSPP 里 L2/R2 永远不动。驱动在 `num_trig == 0`
  时用 GPIO 开关直接驱动 `ABS_Z/ABS_RZ`（有真实模拟触发的板子仍走 ADC 路径）。
  RetroArch 不吃这一套，它按 joydev 编号，所以配置里要写 `l2_btn="6"/r2_btn="7"` 并把 `l2_axis/r2_axis` 置空。
- **PPSSPP 无声是因为 `ppsspp.sh`。** 它按 `.DEVICE`（本镜像里仍是 `RG43H`）强制 `amixer sset 'Playback Path' HP`，
  而 NGP45HT 的喇叭挂在 RK817 自己的 SPK 输出上（功放由 `spk-ctl`/GPIO0_A7 使能）。`firstboot.sh` 把它改回
  `SPK`，同时把 RetroArch 两个 cfg 的 L2/R2 一起改掉；不动 `RG43H` 身份文件，因为很多上游脚本靠它分支。
  注意 dArkOS 自带的 **`/opt/system/Advanced/Fix Audio.sh` 会把 `Playback Path` 设回 `HP`**（第 18 行），在界面上
  跑它本板喇叭就又哑了；恢复办法是 `sudo /usr/local/sbin/ngp45ht-fixes.sh`（幂等）。
- **TF 供电不是 GPIO。** `vccio_sd` 是 RK817 LDO_REG5，两个卡槽共用，只在 TF2 协商时可能被抬压，而 TF1
  上就是 rootfs；共享 dtsi 的 `vcc_sd` GPIO regulator 落在 `GPIO0_A5`，那在本板是一颗游戏按键。
- **USB 是 host 控制器，不是 DWC3。** 板载 WiFi 和 Type-C 都挂在 EHCI/OHCI (`usb@fed00000`/`usb@fed40000`) 上，
  5V 轨是 GPIO 开关（host 在 `GPIO3_C0` **低有效**，OTG 在 `GPIO3_B0` 高有效）。共享 dtsi 直接把
  `usb_host0_ehci/ohci` 设成 disabled，不改就是黑 WiFi。
- **`/boot` 只有 98 MB FAT。** 别在 `/boot` 里堆 `Image.bak-*`；`deploy_kernel.py` 现在把备份写到
  btrfs 上的 `/opt/ngp-boot-backups/`，并在上传前检查剩余空间、用 `cp`+`mv` 原子替换。

## firstboot.sh 与 ngp45ht-fixes.sh（两份不一样，别混）

镜像 rootfs 里 `multi-user.target.wants/firstboot.service` 是 enable 的，所以每次刷卡会跑一次 FAT 上的
`/boot/firstboot.sh`——这就是为什么修正可以只写进 FAT，不必 rw 挂载 btrfs。

- **`boot-firstboot.sh`** 才是出厂放在 `/boot/firstboot.sh` 的那份（逐字节相同）：本板修正 **+ 首启扩容**
  （调用 `/boot/ngp-expand.sh`，见下一节）。**手工运行是安全的**——扩容靠分区实际大小判断，已经是
  大分区就直接跳过；但别在已经扩过容的卡上反复跑，那会把 `/roms` 反复卸载重挂。
- **`firstboot.sh`** 是只做修正的那部分，也就是装机卡上 `/usr/local/sbin/ngp45ht-fixes.sh` 的内容；幂等，
  重复执行打印 "already converged"。要重跑修正（例如你跑了 `/opt/system/Advanced/Fix Audio.sh` 把音频又设回 HP）
  就用它，别用上面那份。
它做四件事：PPSSPP/RetroArch 音频与 L2/R2 修正、首启扩容（下一节）、ES 主题兜底 + 版本号 +
清 WiFi 凭据，以及**密钥卫生**
（marker `/boot/ngp45ht-hygiene.done` 保护，**放在 `/boot` 而不是 `/etc`**：`/etc` 下的 marker 会被一起克隆进
下一个镜像，于是每张刷出来的卡都会静默跳过这一步；克隆前记得删掉 `/boot/ngp45ht-hygiene.done`）：删掉底包里上游作者的 `/etc/ssh/ssh_host_*_key*` 后跑
`ssh-keygen -A`，并把 `/etc/hostapd/hostapd.conf` 里的默认 `ssid`/`wpa_passphrase` 换掉。
~~底包不含任何你的家用 WiFi 凭据：`/etc/NetworkManager/system-connections`、`/var/lib/NetworkManager`
是空的，没有 `wpa_supplicant` 配置，也没有 `.ssh`。~~
**这段是错的，2026-10-17 撤回**：当时是用 `grep` 扫镜像明文做的判断，而 rootfs 是 `compress=zstd:1`——
`/etc/NetworkManager/system-connections/` 下那两个 `.nmconnection`（含明文 `psk=`）躺在压缩 extent 里，
grep 扫不到，于是得出了"干净"的**假阴性**；用户刷卡开机后设备自动连上了家里的 WiFi，这才是真信号。
判定有没有残留凭据只能用 `tools/btrfsls.py`（扫 btrfs 目录项名，元数据不压缩），不能靠明文 grep。
修复：`boot-firstboot.sh` 现在会删掉 `/etc/NetworkManager/system-connections/*`，
且**克隆镜像前必须先让它在实机上跑过一次**（删了之后克隆才干净）。

**怎么确认卫生真的跑过**：`ls /etc/ngp45ht-hygiene.done`，再 `grep -E '^ssid=|^wpa_passphrase=' /etc/hostapd/hostapd.conf`。
如果还是底包带的那对默认值，说明这张卡仍在用上游作者公开的热点口令、以及和所有同源副本共用的 SSH 主机密钥。
2026-10-15 就发现装机卡本身**没跑过**（它的 `/boot/firstboot.sh` 还是加卫生逻辑之前的 3153 字节旧版），
补跑后主机密钥已重生成——因此用普通 SSH 客户端连设备会看到 host key 变更告警，`ssh-keygen -R <设备IP>` 清掉即可。
凡是"先做成镜像、之后又改 firstboot 逻辑"的情况，都要记得已装机那份不会自动更新。

## 首启扩容 `/boot/ngp-expand.sh`（不照抄上游 expandtoexfat.sh）

**现象**：刷完新卡开机**没有 ES 主题**、`/roms` 只有 79 MB。
**根因**：底包的 `/boot/firstboot.sh` 被换成本板修正版时丢掉了 dArkOS 自己的首启步骤，于是
`/roms.tar` 没解开、`/tempthemes`（5 个主题）没拷进 `/roms/themes`，而 ES 配置的 `ThemeSet`
（`es-theme-nes-box`）**只存在于** `/roms/themes` 里——主题目录是空的，ES 就没有主题。
扩容和"没主题"是同一个根因。

`boot-ngp-expand.sh`（装机为 `/boot/ngp-expand.sh`）补上这一步，但**故意不是** `scripts/expandtoexfat.sh.rk3562`：

- 上游还会 `growpart` 第 4 分区（btrfs rootfs）多留 ~11 GB"给以后的更新"。本移植 p4 必须保持
  **12,629,049,344 字节**——发布镜像就是按这个几何切的，p4 一变大这张卡就再也克隆不出 12 GiB 镜像。
  所以 ROMS 直接吃掉 p4 之后**全部**剩余空间（p4 11.76 GiB 里才用了 ~2.5 GiB，本来就该给 ROM）。
- 上游最后 `cp /boot/fstab.exfat /etc/fstab`，那会**冲掉双卡 mergerfs 池**；这里改走
  `ngp-rompool.sh install` + `merge`。
- 上游跑 dialog 进度条、末尾 reboot；这里全部写 `/boot/ngp-firstboot.log`（在 FAT 上，PC 直接能看），
  并且**原地**把池挂起来，ES（`After=firstboot.service`）一次开机就能用，不需要二次重启。
- "已经扩过了"由**分区实际大小**判断（p5 ≥ 1 GiB），**不用 marker**：脚本本身在镜像里，任何 marker
  都会被一起克隆，那样每个用户的首启都会跳过他们真正需要的扩容。唯一的例外是重启重试计数
  `/boot/ngp-expand.retries`（成功时脚本自己删），克隆前确认它不在。
- 每次开机都会跑一遍（firstboot 服务要留着 enabled），所以开头有快速路径：
  `/roms` 已经是带主题的 mergerfs 池就直接退出，不做无谓的卸载重挂。

日志看 `/boot/ngp-firstboot.log`。**克隆镜像前要清掉**：`ngp-firstboot.log`、`ngp45ht-hygiene.done`、
`ngp-expand.retries`。

## 调试

设备 SSH 是 `ark`/`ark`（dArkOS 默认），root 走 `echo ark | sudo -S -p ''`。
**SSH 只在设备上打开 Settings → Options → "Enable Remote Services" 后监听，而且不跨重启保留**
（上游把 `enable` 那行注释掉了），所以每次重启后 22 端口被 RST 是正常的，不是网络坏了；能 ping 通但所有
TCP 端口关闭就是它的特征。已装机的卡上额外手动 `systemctl enable ssh`（**没有**放进发布镜像）。
`tools/ngpremote.py` 提供 `shot`/`view`/`btn`/`hold`/`key`，看屏幕和注入按键都不用碰设备。

最强的免费对照组是 eMMC 里的原厂 EmuELEC（拔 TF 卡启动，`root`/`emuelec`）：它的
`/proc/device-tree`、`/sys/kernel/debug/pinctrl/*/pinmux-pins`、`regulator_summary`、`mmcN/` 就是
已知良好状态，直接 diff。原厂 UI 左上角那颗手柄图标每按一次键闪一下，可以零工具判断"这个开关在原厂好不好"。

## 现状

已验证：从 TF 启动、面板点亮、btrfs 根挂载、EmulationStation 运行、WiFi 拿到地址并可出网、
17 个按键全部上报、TF2 枚举（`/dev/mmcblk2` + FAT32 分区，上游 `Switch to SD2 for Roms.sh` 可用）、
摇杆方向与极性正确、PPSSPP 有声音且 L2/R2 可用、slim 内核下帧率正常。

未做 / 保留意见：

- **板载蓝牙是 LE-only：能扫描、能配对、能维持链路，但经典蓝牙（A2DP 音频、HIDP/DInput、XInput）原理性不可用。**
  AIC8800DC 的蓝牙和 WiFi 是同一颗 USB 设备的不同接口（`hci0` 由 `btusb` 从 `1-1:1.0` 建，WiFi 在 `1-1:1.2`）。
  2026-10-16 用厂商 `aic_btusb` 打到底：`CONFIG_BLUEDROID=0`（用 `nm -u` 确认它引用内核的
  `hci_alloc_dev`/`hci_register_dev`）+ `CONFIG_PLATFORM_UBUNTU=n` + `CONFIG_USE_FW_REQUEST=n`（它按
  `/lib/firmware/aic8800DC/` 直接 `filp_open`，不走 `request_firmware`）。probe 读到 `chip_id=c7, sub_chip_id=2`
  → `_u02h` 分支；原厂 `download_patch()` 里 `check_fw_status()` **返回芯片给的 0 就被当作"已在运行"从而跳过下载**，
  把那个条件强改成 `if (1)` 之后补丁完整灌入：`fw_patch_table_8800dc_u02h.bin`(640 B) +
  `fw_patch_8800dc_u02h.bin`(17,772 B)、`patch version - Jul 23 2025 14:07:14 - git 4e4e31c`、
  `fw_patch_table download complete`。灌完再 `btmgmt power off/on` 重读，`Features` 仍是
  `00 00 00 00 60 00 00 00`、`SCO MTU 0:0`、`btmgmt` 仍无 `bredr`，手工发 `Read Local Name` 回
  `05 14 0C …`、`Read Buffer Size` 回 `05 03 0C 00`（**HCI status 0x05 = 该命令不存在**）。
  → 缺的不是驱动、不是补丁、不是配对应答程序，而是**镜像里没有经典蓝牙协议栈**；补丁只是 ROM 之上的 patch。
  原厂 EmuELEC 6.1.118 量到同样特征且 `bluetooth.service` 出厂 disabled，原厂 DTB 里的
  `wireless-bluetooth`/`uart1-gpios` 是 EVB 参考设计遗留（`uart1m0_xfer` = GPIO1_D1/D2 在本机是 L1/L2 按键）。
- **LE 侧已经完全可用**，这是本次最实质的进展：装好配对应答 agent（`tools/ngp-bt-agent.py` +
  `ngp-bt-agent.service`，`RegisterAgent(o,s)` + `RequestDefaultAgent`，自动接受确认、`RequestPinCode` 回 `0000`）
  之后，机械师 G3V2 PRO **`Pairing successful`**，并留下活链路
  `hcitool con` → `< LE 98:B6:ED:xx:xx:xx handle 18 state 1 lm CENTRAL`（手柄地址已抹掉），`hciconfig` 的 `acl:` 从 0 涨到 18。
  `/dev/uinput`（misc 10:223，0666，内核内建）、`python3-evdev`、`bluetoothd` 里的 hog 串都在，
  **所以标准 BLE HID(HOGP) 的手柄可以在这块板上直接配对即用**；要 BT 音频仍然只能上 btusb 认识的 USB dongle
  并安装 bluealsa（dArkOS 自己的构建注释就写着 `USB dongle required`）。
- **G3V2 PRO 在板载蓝牙下用不成，原因在手柄侧。** 它蓝牙侧只有厂商 APP 协议：GATT 是
  `0000ff12`（`ff13` write / `ff14` notify / `ff15` read，read 返回 `00 00 00 00`）加
  `d7f010e0-660d-46e9-96c3-19c4148bdab5`（`…e1` write / `…e2` notify），**没有 HID Service `00001812`**。
  两个 notify 特征 `StartNotify` 都成功，但边按按键边抓 90 秒**一条通知都没有**；再按 10 Hz 轮询唯一可读的
  `ff15` 共 60 秒（约 600 次 `ReadValue`）**恒为 `00 00 00 00`**，所以它不是数据寄存器 —— 手柄只在收到主机发出的
  未知厂商握手命令后才开始上报，社区也搜到这套 UUID 的公开实现，故不在这里逆向。
  另注：EmulationStation「选项 → Bluetooth → activate existing Bluetooth device」里选它显示**连接成功是实话**
  （`hcitool con` → `< LE … handle 18 state 1 lm CENTRAL`），但那只是 LE ACL 链路：GATT 表里没有 `00001812`，
  `/proc/bus/input/devices` 不增加任何设备、`hidraw` 为空，**RetroArch 读不到任何东西**。而它切到 DInput 后我们的 LE 扫描**什么都看不见**（经典 HID 不发 LE 广播），
  与上面 LE-only 的结论完全吻合 → **DInput 走板载蓝牙是原理性无解，不是没配对上**。
  这台掌机上要用手柄，优先 **2.4G 接收器 / 有线 USB**：`usbhid`、`hid`、`hidp` 都内建在 Image 里，
  `hid-generic`/`hid-multitouch` 已在总线注册，插上即出 `/dev/input/eventN`，不需要任何移植。
- **可借用的第三方做法**：`tools/btaic.sh`/`btaic2.sh` 是上面那套驱动实验的可复现脚本（全部可逆，实验期间 WiFi
  始终 0% 丢包；注意 `reboot` 不给芯片掉电，厂商补丁会留在 RAM 里）。别人移植方案里的
  "BT/外接手柄在场时卸掉自带手柄、断开再挂回"这一招在我们卡上路径完全对得上：
  `echo play_joystick > /sys/bus/platform/drivers/rk3562-joystick/unbind`（`bind` 反向），
  驱动目录名与设备名和他写死的一字不差。
- EmulationStation 的面键映射里 `a`→305、`b`→304，即机身上 **B 键是确认**。这是 owner 明确决定保留的
  （"不用改了"），不要当成 bug 再去"修"。
- mainline 7.2.x 目前带不动这块板：RK3562 的 CRU、pinctrl、gpio、i2c、spi、uart、pwm、saradc、
  dw-mmc、pcie、combphy、otp 和 GPU 都已进主线，但 **DSI、VOP、IOMMU、USB2-PHY/EHCI/OHCI/DWC3、
  I2S/SAI/SPDIF、thermal、DMC、RGA、VPU 都还没有**，也就是没屏幕、没 USB（⇒没 WiFi）、没声音。
  真要上主线得先把这几套驱动补完，成本远高于继续用 5.10 BSP。
- 发布镜像 `dArkOS_ngp45ht_trixie_20261015.img.xz`（4,502,192,424 B，sha256 `a0f7c41a…`，三卷哈希与拼接说明见
  [`CHANGELOG.md`](CHANGELOG.md)）不在 git 里，GitHub 单文件 2 GiB 上限所以切成三卷。它不是从 build tree 完整
  构建出来的，而是 RG43H 底包 + `fatpatch.py` 换 Image/DTB/firstboot + rootfs 侧装模块和内核组装的，
  所以照着上面的步骤能得到同款内核与 DTB，但整张卡的组装流程还没有脚本化。
- 镜像里的 rootfs 只剩约 224 MB 空闲（97 % 用满），往里塞东西前先看 `df`，否则 btrfs 会在写入中途爆掉。
