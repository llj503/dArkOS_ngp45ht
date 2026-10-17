# NGP45HT 屏幕色温 / 画面调节（从 ROCKNIX 移植）

## 来源

上游：`AveyondFly/distribution_rocknix`（branch `next`）的
`projects/ROCKNIX/packages/rocknix/sources/scripts/paneladj`
（最初来自 JELOS，GPL-2.0）。取其 RK356X 分支的机制：**VOP2 BCSH
后处理器的四个 DRM 连接器属性** `brightness` / `contrast` /
`saturation` / `hue`，取值 0-100，50 = 中性。

内核侧语义（`rockchip_drm_vop2.c` `vop2_tv_config_update()`，已核对源码）：

| 属性 | 硬件映射 | 0 | 100 |
|---|---|---|---|
| brightness | 亮度偏移（8bit 路径 -32..+31） | 最暗 | 最亮 |
| contrast | 对比度 0..511 | 无对比度 | 最大 |
| saturation | 饱和度 0..511 | 灰度 | 最大 |
| hue | 色相旋转 -30°..+30° | -30° | +30° |

四个都是 50 时驱动直接旁路 BCSH（零开销默认态）。属性值存在 DRM 对象里，
之后任何一次 atomic commit（ES / RetroArch 出图）都会重新应用——只有重启
才会丢失，所以需要开机恢复服务。

## 与上游的差异（都是有意为之）

1. **不用 modetest**：`panelprop.py` 用 ctypes 直调系统自带的
   `libdrm.so.2` 做同样的 `drmModeObjectSetProperty()`。卡片上
   `/dev/dri/card0` 属 `video` 组、`ark` 在 `video` 组，**不需要 sudo，
   也不需要 apt 装任何东西**。
2. **不用 ROCKNIX 的 sysconfig**：设置持久化到
   `/opt/ngp-panel/panel.conf`。dArkOS 的 SD-switch 脚本会 `sed` 所有
   `/roms` 路径，所以持久资产必须放 btrfs 系统卡的 `/opt`。
3. `HW_DEVICE` 恒为 RK356X，只走连接器路径（无 sway / CRTC 回退）。
4. **brightness 下限 5**（与上游 006-display 开机脚本相同），防止菜单里
   把屏幕调到不可用的黑。

## 文件布局

```
/opt/ngp-panel/panelprop.py     DRM 属性读写（ctypes + libdrm）
/opt/ngp-panel/paneladj.sh      paneladj 移植版（CLI）
/opt/ngp-panel/panel.conf       持久化设置（ark 可写）
/opt/ngp-panel/README.md        本文件
/opt/system/Screen Color.sh     ES 系统选项里的对话框前端
/etc/systemd/system/ngp-panel-restore.service   开机恢复（已 enable）
```

`paneladj.sh` 用法：

```bash
/opt/ngp-panel/paneladj.sh brightness 30      # 直接设值
/opt/ngp-panel/paneladj.sh contrast up        # +1
/opt/ngp-panel/paneladj.sh hue down           # -1
/opt/ngp-panel/paneladj.sh value saturation   # 读当前值
/opt/ngp-panel/paneladj.sh restore            # 重放持久化值（开机用）
```

## 已知限制

- **对话框只能用英文**：本机控制台 744 个 PSF 字体无一支持 CJK，中文会
  变成方框；ES 菜单字体（Cabin）同样只有拉丁文。所以菜单项叫
  `Screen Color`。
- **效果在 ES 重绘后可见**：属性写入即时生效于驱动，但屏幕像素要等下一
  次 atomic commit（ES/RetroArch 出图）才会变——退出工具后动一下方向键
  即可看到，与 ROCKNIX 行为一致。
- 与基础镜像自带的 `panel-lut.service`（RG43H 面板补偿 3D LUT，
  CUBIC_LUT）**不冲突**：LUT 与 BCSH 是 VOP2 里两个独立后处理块，叠加
  生效。注意那个 LUT 是按 RG43H 面板校准的（目标 ~5650K 暖白），对
  NGP45HT 面板并非最优——如需重新校准可用
  `/usr/local/bin/make-panel-lut`（需要本机面板的色度参数）。

## 卸载

```bash
sudo systemctl disable --now ngp-panel-restore.service
sudo rm /etc/systemd/system/ngp-panel-restore.service
sudo rm -rf /opt/ngp-panel "/opt/system/屏幕色温.sh"
sudo reboot
```

## 中文字体（2026-10-17 追加）

两个显示面原本都没有 CJK 字形，已分别解决：

**1. 控制台（dialog 界面用）**——`/usr/share/consolefonts/Unifont-CJK-panel.psf.gz`
- 来源：GNU Unifont 16.0.03 BDF，由 `mkpsf.py` 本地转换（转换器在移植仓库里）
- 约束：**内核 VT 单字体最多 512 个字形位**（vt.c `con_font_set`：charcount > 512 直接 EINVAL），所以只收录本界面用到的 269 个符号（ASCII + dialog 的 11 个制表符 + UI 全部汉字/全角标点）
- 坑1：`bdf2psf` 用 `AVERAGE_WIDTH` 推断字宽，Unifont BDF 是混合宽度（ASCII 8px、汉字 16px），16px 行会被整行跳过——所有汉字静默丢失，必须用 `mkpsf.py` 自己转
- 坑2：**必须是 PSF2**——PSF1 字头不存宽高，kbd 强制按 8px 宽解释（charsize 当高度），16×16 汉字会被拉成 8px 竖条（症状：全是拥挤竖线、看不清字；且几何变 128×24，与 64×48 同为 3072 字节会骗人）。PSF2 字头 magic 0x864ab572、32 字节、显式存 width/height
- 坑3：**unicode 表格式 PSF1/PSF2 不同**——PSF1 是 u16 LE 码位 + 0xFFFF 分隔；PSF2 是 **UTF-8 字节 + 0xFF 分隔**（0xFE 起序列）。混用报 "trailing garbage"
- 坑4：**全角标点 （）：。Unifont 里是有的**（FF08/FF09/FF0C/FF1A/3002），可直接用
- 加载/恢复由 `屏幕色温.sh` 在运行期间自己做（进入加载、退出恢复 Lat7-Terminus20x10）

**2. ES 菜单**——无需装字体：ES 自带缺字回退 `/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf`（镜像里已有），主题字体（Cabin）没有的汉字由它回退渲染，所以菜单项直接改中文名 `屏幕色温.sh` 即可。

**验证方法**（无需肉眼）：`mknod /dev/vcsu1 c 7 65` 后读该设备得 char32 字符流（普通 /dev/vcs1 走 noattr 路径只给字形索引低字节）；字形索引可用普通 /dev/vcs1 回读比对。**远程截图看真实渲染**：`ffmpeg -f kmsgrab -framerate 30 -i - -vf "hwdownload,format=bgr0,format=rgb24" -frames:v 1 -f rawvideo -pix_fmt rgb24 -y /tmp/x.rgb` 拉回本地转 PNG——注意 /dev/fb0 读到的不是真实扫描输出（ES 走 DRM pageflip 时 fb0 只是 fbcon 表面），会误判黑屏。

**本机 Python**：`C:\Users\llj\.workbuddy\binaries\python\envs\default\Scripts\python.exe`。
