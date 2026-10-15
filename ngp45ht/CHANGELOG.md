# 更新记录

## 2026-10-15 · `dArkOS_ngp45ht_trixie_20261015.img.xz`

改动**只在 p4 rootfs**。p3 FAT 与 20261013 版逐字节相同：
`Image` `4216e2244c3b74cd…`(32,522,752 B，`ngp45ht_defconfig`)、`rk3562-ngp45ht.dtb` `f716f3077b4e1aa1…`、
`firstboot.sh` `8c1a37e6281a0a37…`（loop 挂载 offset 16777216 复核）。

- **47 个 libretro 内核刷新**：来源 `christianhaitian/retroarch-cores` 分支 **rg503**（dArkOS 对所有非 rk3326
  板子都用 rg503），也就是 `build_retroarch.sh:98` 当年 wget 的同一个仓；每个内核的构建日期取自分支自带的
  `aarch64/.index-extended`。镜像之后被重建过 52 个，其中 49 个字节真的不同，全部替换并逐个 md5 校验；
  `arduous`/`chimerasnes`/`minivmac` 只是重建、字节相同。净增 13.2 MB（先删旧再写新，所以放得下）。
- **两个回滚**：`DoubleCherryGB` 和 `np2kai` 换新版后反而引用了本 rootfs 没有的符号
  （`utf8skip` / `ymzadpcm_getpcm`），保持镜像原版本。
- **一个原本就坏的内核被顺带修好**：旧版 `fake08` dlopen 直接 SIGILL，根本加载不了；新版正常。
- 新增 `/usr/local/sbin/ngp-core-update.sh`（`b5b7f707b036…`）：plan / check / install / verify / compare /
  rollback，`--32` 切 32 位目录；刷出来的卡和现役卡用同一个入口继续更新。
- 新增 `/usr/local/share/ngp-cores/manifest-20261015.txt`：这次换掉的 47 个内核的名字与 md5。
- 内核源码有了真正的仓库：4 处改动是 **`llj503/kernel_rk3562` 分支 `ngp45ht`**（`56dced3ff`，父提交
  `557e5c28a`）上的 4 个正式提交，`_repo` 的子模块已指向它（`git submodule update --init kernel_rk3562` 直接拿到
  打好补丁的内核）；`kernel-patches/*.patch` 由 `git diff 557e5c28a..HEAD` 重新生成，两者内容一致（用
  `git apply --check --reverse` 四个补丁逐一验证过）。

**没有变化的东西**：RetroArch 仍是 1.22.2 —— 这就是上游最新 release，也是基线 pin 的版本，再往上只有 nightly，
代价是所有内核 ABI 连坐；PPSSPP v1.20.4 同理；卡上的 MAME 内核已经是 0.281。

### 下载与校验

GitHub 的 release 单文件上限是 2 GiB，所以整包按 1.9 GB 切了三卷：

| 文件 | 大小 | sha256 |
|---|---|---|
| `dArkOS_ngp45ht_trixie_20261015-00.img.xz.part` | 1,992,294,400 | `fa17f772f4281a07976ebc48cc7e8ef75c2cb5fa914dc84e5db02c51586bdd92` |
| `dArkOS_ngp45ht_trixie_20261015-01.img.xz.part` | 1,992,294,400 | `92f9f1a29189101775d087ce35fb523ad5a324d2cf7c8f19a81025c2ca676291` |
| `dArkOS_ngp45ht_trixie_20261015-02.img.xz.part` | 518,430,984 | `cbc720c4141f36e3b459063641b5645403a57f08bd0da00b37d0db6b9d3d79b2` |

合并后整包 `dArkOS_ngp45ht_trixie_20261015.img.xz` = 4,503,019,784 B，
sha256 `76e0bcbe307811627db3637e253d10e9ee3b7f14b09259d6bfc8bb8d01af8053`，解压后 12 GiB（12,884,901,888 B）。

```bash
cat dArkOS_ngp45ht_trixie_20261015-*.img.xz.part > dArkOS_ngp45ht_trixie_20261015.img.xz
echo "76e0bcbe307811627db3637e253d10e9ee3b7f14b09259d6bfc8bb8d01af8053  dArkOS_ngp45ht_trixie_20261015.img.xz" | sha256sum -c -
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
