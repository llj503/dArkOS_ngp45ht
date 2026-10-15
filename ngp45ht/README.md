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
| `tools/devsh.py` | 把本地 `.sh` 推到卡上以 ark 身份执行（顺手去 CRLF），例如 `python devsh.py ngp-core-update.sh plan` |
| `tools/deploy_kernel.py` | 通过 SSH 把 Image + DTB 写到已装机的卡上（带空间检查和哈希校验） |
| `tools/ngpremote.py` `tools/remote_dev.py` | PC 端看屏幕 + 注入按键（1024×768 横屏，PC 只需 Pillow） |
| `tools/*.py` 其余 | 硬件探针：GRF/GPIO/CRU 寄存器、PMIC I²C、按键与 ADC 录制、引脚占用归属 |
| `firstboot.sh` | 装到镜像 FAT 分区，首次开机跑一次；在已装机的卡上等价于 `/usr/local/sbin/ngp45ht-fixes.sh` |

`tools/` 里保留了调试期的探针脚本，它们记录了每个结论是怎么量出来的；`assemble.sh`、
`kbuild.sh`、`kbuild2.sh` 是过程历史，日常只需要 `slimbuild.sh` / `dtbrebuild.sh` / `fatpatch.py`。
脚本顶部的 `/mnt/f/darkos/...` 是原作者的机器路径，用之前改成自己的。

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
- **TF 供电不是 GPIO。** `vccio_sd` 是 RK817 LDO_REG5，两个卡槽共用，只在 TF2 协商时可能被抬压，而 TF1
  上就是 rootfs；共享 dtsi 的 `vcc_sd` GPIO regulator 落在 `GPIO0_A5`，那在本板是一颗游戏按键。
- **USB 是 host 控制器，不是 DWC3。** 板载 WiFi 和 Type-C 都挂在 EHCI/OHCI (`usb@fed00000`/`usb@fed40000`) 上，
  5V 轨是 GPIO 开关（host 在 `GPIO3_C0` **低有效**，OTG 在 `GPIO3_B0` 高有效）。共享 dtsi 直接把
  `usb_host0_ehci/ohci` 设成 disabled，不改就是黑 WiFi。
- **`/boot` 只有 98 MB FAT。** 别在 `/boot` 里堆 `Image.bak-*`；`deploy_kernel.py` 现在把备份写到
  btrfs 上的 `/opt/ngp-boot-backups/`，并在上传前检查剩余空间、用 `cp`+`mv` 原子替换。

## firstboot.sh

镜像 rootfs 里 `multi-user.target.wants/firstboot.service` 是 enable 的，所以每次刷卡会跑一次 FAT 上的
`/boot/firstboot.sh`——这就是为什么修正可以只写进 FAT，不必 rw 挂载 btrfs。脚本幂等，重复执行会打印
"already converged"；已装机的卡上该 unit 是 disabled 的，等价入口是 `/usr/local/sbin/ngp45ht-fixes.sh`。
它做三件事：PPSSPP/RetroArch 音频与 L2/R2 修正、把上面的逻辑再落一遍、以及**密钥卫生**
（marker `/etc/ngp45ht-hygiene.done` 保护）：删掉底包里上游作者的 `/etc/ssh/ssh_host_*_key*` 后跑
`ssh-keygen -A`，并把 `/etc/hostapd/hostapd.conf` 里的默认 `ssid`/`wpa_passphrase` 换掉。
底包不含任何你的家用 WiFi 凭据：`/etc/NetworkManager/system-connections`、`/var/lib/NetworkManager`
是空的，没有 `wpa_supplicant` 配置，也没有 `.ssh`。

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
