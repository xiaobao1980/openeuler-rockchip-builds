# openeuler-rockchip-builds

把 **openEuler 用户态** 嫁接到 **Armbian 已经验证过能启动的 bootloader + vendor 内核** 上，为 RK35xx 全系板卡产出可烧写镜像。

不编译内核、不编 U-Boot、不跑 `compile.sh`。全程只做文件操作，一块板 10–20 分钟出结果。

## 已验证（2026-11-09 实跑）

| 环节 | 结果 |
|---|---|
| arm64 runner | `ubuntu-24.04-arm`，4 核 / 15 G RAM / 107 G 空闲，public 仓库免费 |
| boot 资产 | `boot-orangepi5-plus-6.1.115.tar.zst` 37 MiB（Image 45 M + modules 142 M + bootloader 16 MiB） |
| 镜像构建 | `out.img` 2.8 G，`verify-image.sh` **21 项全过** |
| 发布产物 | `openEuler-24.03-LTS-SP4-orangepi5-plus-6.1.115-20261109.img.xz` **704 MiB** |
| 集成安装 `node-red,mosquitto` | rootfs 1.5 G → **2.8 G**，镜像 3.2 G，`verify-image.sh` **37 项全过**，产物 **712 MiB** |
| 集成安装 `node-red,mosquitto,z2m` | rootfs **3.3 G**，镜像 3.7 G，**41 项全过**，产物 **776 MiB**（pnpm + tsc 构建耗时约 +8 分钟） |
| `h96-m9` boot 资产 | `boot-h96-m9-6.1.172.tar.zst` **34 MiB**；来源 `armbian-custom-builds@h96s-20261109-r37`，MANIFEST：`kernel=6.1.172-vendor-rk35xx`、`dtb=rk3576-h96-m9s.dtb` |
| `h96-m9` 集成安装 `node-red,mosquitto` | 镜像 **3.2 G**，分区起点 LBA 32768 校验通过，`verify-image.sh` **37 项全过**，产物 **708 MiB**（Release `h96-m9-iot-20261109-r9`，19 分钟；坑 #18 + #19，**别刷**） |
| `h96-m9` IoT 修复版（extlinux 路径） | `kernel /boot/Image` + `fdt /boot/dtb/...` + 根硬链接兼容层；**41 项全过**（新增 4 项把 conf 路径落地断言），产物 **710 MiB**，Release `h96-m9-iot-20261109-r10`（15 分钟；真机证明内核能起但卡在 root 挂载 = 坑 #19，**别刷**） |

> 上面带板名的行都是 `h96-m9` 实跑；未带板名的是 `orangepi5-plus` 基线实跑。
> ⚠️ r9 / r10 的 `.img.xz` **文件名完全相同**（按日期命名，同一天重跑撞名），必须按 **Release tag** 取，别按文件名。后续构建的产物名已带 `-r<run>`。
> 🌐 跨板：路径重写与 4 项校验在共用 `scripts/` 里，其它 RK35xx 板同样受益。
>
> **真机两轮（2026-11-10，H96 MAX M9，串口 1500000 8N1）**：第一轮 DDR → BL31 → U-Boot 2017.09 全正常，卡在 `Retrieving file: /Image → ** File not found /Image **`（坑 #18）；修好路径后第二轮 `/boot/Image` + DTB 加载成功、`Starting kernel ...` 后内核完整起来（8 核 / HDMI / USB / eMMC 全起），却卡在 `Waiting for root device UUID=...`（坑 #19）。两轮都是「静态校验全过、真机起不来」，分别补了「conf 路径 ↔ 实体文件」和「cmdline ↔ GPT 分区表」两组闭环断言。**尚未看到**：`VFS: Mounted root (ext4 filesystem)`、systemd 登录提示符、sshd / Node-RED / Mosquitto 首启。

---

## 为什么是「嫁接」而不是「移植」

```
BootROM → rkbin(DDR+BL31) → U-Boot(TPL/SPL) → kernel+DTB → rootfs
  芯片固定      芯片固定          板级            板级        与 SoC 无关
```

`openEuler` 的 rootfs 是 aarch64 通用的（glibc + systemd + rpm），与 SoC 无关。所谓「openEuler 适配 RK35xx」，真实工作量全在前四层，而前四层你已经在 Armbian 上做完了。

于是本仓库只做一件事：**换掉最后一层，其余原样保留。**

| 输入 | 来源 | 内容 |
|---|---|---|
| rootfs | openEuler 官方 `virtual_machine_img/aarch64/*.qcow2.xz` | 完整可启动系统（含 sshd / NetworkManager / firewalld / selinux-policy） |
| bootloader | Armbian 已验证镜像的前 16 MiB | MBR + GPT + idbloader + u-boot.itb |
| kernel | 同一镜像的 `/boot` | `Image` + `dtb` + `/lib/modules/<ver>` |

> 不用 openEuler 官方 `docker_img`（仅 41 MB）：缺 sshd、NetworkManager、firewalld、selinux-policy，不能当宿主系统。

---

## 为什么单独建一个仓库

塞进 `armbian-custom-builds` 也能跑，但会有三个副作用：

1. **构建语义完全不同**。那边是「编译 Armbian 镜像」，这边是「拼装现成材料」。混在一起后 `build-all.yml` 的板卡矩阵会被污染。
2. **Release 命名空间冲突**。那边 tag 是 `h96-m9-20261109-r12`，这边是同一块板的 openEuler 产物，混在一个 Release 列表里没法追溯。
3. **依赖方向被搞反**。本仓库**消费** Armbian 产物，不该反过来和产出方耦合在同一个仓库里。现在的关系是单向的：`armbian-custom-builds` → `boot assets` → `openEuler image`。

---

## 支持范围：98 块板

板卡清单**不手写**，由 `scripts/sync-boards.sh` 从上游 [armbian/build/config/boards](https://github.com/armbian/build/tree/main/config/boards) 同步：

| SoC | 板卡数 | 家族名 |
|---|---|---|
| rk3588 | 25 | `rockchip-rk3588` |
| rk3588s | 16 | `rockchip-rk3588` |
| rk3576 | 16 | `rk35xx` |
| rk3568 | 15 | `rk35xx` |
| rk3566 | 12 | `rk35xx` |
| rk3528 | 11 | `rk35xx` |
| rk3562 | 1 | `rk35xx` |
| **合计** | **96** 可构建 + 2 块缺 DTB | |

上游新增一块 RK35xx 板 → 下次跑 workflow 自动出现，**不需要改本仓库任何文件**。

> ⚠️ `boards.tsv` 只含上游收录的板。**自定义板（如 `h96-m9`）不在上游**，只存在于
> `boards/<id>/board.conf`。CI 矩阵走 `scripts/list-boards.sh` 合并两个来源，
> 只读 TSV 的话选 `h96-m9` 会得到 0 块板直接失败。

两块 `NO_DTB`（上游用 `fdtdir` 自动匹配，拿不到确切 dtb 名）：`friendlyelec-rk3588`、`orangepi3b`。要用就手写一份 `boards/<id>/board.conf`。

**全系能共用一套脚本，因为只有三样东西真的跟板子走：**

- DTB 文件名（`boards/boards.tsv` 里）
- CMA 大小（按 SoC 推导）
- 分区起点（从 bootloader 区自带 GPT 实测，配置值只是兜底）

其余全家族一致：`idbloader @LBA64`、`u-boot.itb @LBA16384`、`分区1 @LBA32768`、串口 `ttyS2 @1500000`、内核 `6.1.172-vendor-rk35xx`（`rk-6.1-rkr7.2` 一支内核同时覆盖 3528/3566/3568/3576/3588）。

---

## 快速开始

### 1. 先产出某块板的 boot 资产（一次，内核不变就不用重发）

> ⚠️ **这是硬依赖**。两个 build workflow 都在「解析板级配置」步按 `boot-<board>-*` 前缀查 Release，缺了就约 30 秒失败，日志里只有 `没有 boot 资产 Release` 一行——**不会自动去下载 Armbian 镜像**。分层是刻意的，见「为什么单独建一个仓库」。

走 CI（`Publish boot assets`），给 Armbian 产物仓库 + Release tag，或给一个 `.img.xz` 直链：

```bash
gh workflow run publish-boot-assets.yml --repo xiaobao1980/openeuler-rockchip-builds --ref main \
  -f board=h96-m9 \
  -f armbian_repo=xiaobao1980/armbian-custom-builds \
  -f armbian_tag=h96s-20261109-r37

# 约 2~3 分钟后确认产出（tag 里的内核号是短版本，真实值看资产内 MANIFEST.txt）
gh release view boot-h96-m9-6.1.172 --repo xiaobao1980/openeuler-rockchip-builds
```

在板子上直接抓也行——**原始素材，保真度最高**：

```bash
git clone https://github.com/<you>/openeuler-rockchip-builds && cd openeuler-rockchip-builds
sudo BOARD=h96-m9 ./scripts/make-boot-assets.sh --from-dev /dev/mmcblk0
gh release create boot-h96-m9-6.1.172 out/boot-h96-m9-6.1.172.tar.zst*
```

### 2. 构建 openEuler 镜像

`Actions → Build openEuler Image → Run workflow`：

| 输入 | 说明 |
|---|---|
| `boards` | `h96-m9` / `h96-m9,radxa-rock-4d` / `all` / `soc:rk3576` |
| `oe_version` | 默认 `24.03-LTS-SP4`（Rockchip 生态最成熟） |
| `selinux` | **首次必须 `disabled`**，跑通再谈策略 |
| `cma_override` | 留空=按 SoC 自动 |

或用 CLI：

```bash
gh workflow run build-openeuler.yml -f boards=h96-m9 -f selinux=disabled
```

### 3. 烧写

```bash
xz -dc h96-m9-*.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

> ⚠️ 只刷 **修好 extlinux 路径之后**构建的镜像（`h96-m9-iot-20261109-r9` 及更早的 r 版本有坑 #18，会停在 `File not found /Image`）。旧卡也可以不重刷，按坑 #18 的两条硬链接热修。

串口 `1500000 8N1` 应看到 `U-Boot → extlinux → systemd`。首次登录后 `passwd` 改密码；要用满整卡：

```bash
growpart /dev/mmcblk0 1 && resize2fs /dev/mmcblk0p1
```

---

## 集成安装：IoT 网关镜像（可选）

`Actions → Build openEuler IoT Image` 在同一个拼装流程上多烘焙一层服务栈，产出**烧完开机即可用**的网关镜像，不用上板后再联网装一遍。

| 组件 | 端口 | 管理 |
|---|---|---|
| Mosquitto MQTT | 1883 | `systemctl status mosquitto` |
| Mosquitto WebSocket | 8083 | `ws://<IP>:8083`（IoTManager / MQTT.js） |
| Node-RED | 1880 | `systemctl status node-red` |
| Zigbee2MQTT | 8080 | `systemctl status zigbee2mqtt` |

参考实现是 `iot/install_nodered_z2m_ubuntu24_v3.5.sh`（在线装在已运行的 Ubuntu 上），烘焙进镜像必须换三样东西：

| | 原脚本（在线装） | 本仓库（烘焙进镜像） | 为什么 |
|---|---|---|---|
| 包管理 | `apt` | `dnf`，**mosquitto 走 EPOL 仓** | openEuler 的 OS 仓没有 mosquitto；脚本会自动按现有 repo 的主机名与版本号拼 EPOL 源，不硬编码 |
| 进程管理 | PM2（`pm2 startup` + dump） | **systemd 原生 unit** | sealed 镜像没有「用户登录」这回事，PM2 的 resurrect 依赖 `/home` 下的 dump，属于自找麻烦 |
| 路径/权限 | `$HOME/.node-red`、`$HOME/.pm2`，用户态 | `/var/lib/{node-red,zigbee2mqtt}`，独立系统用户 | 服务不跑 root；`nodered` / `zigbee2mqtt` 由构建时创建 |

**一个意外的好消息**：openEuler 的 `mosquitto-2.0.20` 已链接 `libwebsockets.so.19` —— 天生支持 8083 WebSocket。原脚本里「apt 版没 WS，要不要源码编译」这个纠结在这里**整个不存在**，dnf 装完就有。（脚本仍会实测 `grep -aq libwebsockets.so`，万一某版本没编 WS 就不写 `listener 8083`，否则整个 broker 起不来。）

```bash
# 完整栈（含 Z2M，构建时间 +8~12 分钟：源码 clone + pnpm install + tsc）
gh workflow run build-openeuler-iot.yml \
  -f board=h96-m9 -f stack=node-red,mosquitto,z2m \
  -f zigbee_coord=tcp://192.168.30.107:8888 -f zigbee_adapter=ezsp

# 只要 MQTT + Node-RED（约 6 分钟）
gh workflow run build-openeuler-iot.yml -f board=h96-m9 -f stack=node-red,mosquitto
```

协调器留空也能构建：镜像里写好注释占位，首启编辑 `/opt/zigbee2mqtt/data/configuration.yaml` 再 `systemctl restart zigbee2mqtt`。

> 只装不跑校验的坑：Z2M 在协调器不可达时会 `Restart=on-failure` 反复重启，这是**正常现象**，不是镜像坏了。

**Z2M 的构建产物判据容易写错**：`lib/` 顶层只有 `controller/eventBus/mqtt/state/zigbee.ts`，**没有 `index.ts`**；真正的入口是仓库根的 `index.js`（`package.json` 的 `main` 与 `scripts.start` 都是它），内部 `require("./dist/controller")`。`tsconfig` 只 `include ./lib/**`，所以 `tsc` 永远不会产出 `dist/index.js` —— 判 `dist/index.js` 会得到「构建成功但没有产物」的假象。正确判据是 `dist/controller.js`。

---

## 目录结构

```
boards/
├── boards.tsv              # 98 块板清单（自动生成，勿手改）
├── _template/board.conf    # 通用推导模板（改默认值只改这里）
├── h96-m9/board.conf       # 手写覆盖：已验证的板，含实测 UUID/CMA
└── neardi-lz200/board.conf # 手写覆盖：示例第二块板

scripts/
├── sync-boards.sh          # 从上游 armbian/build 同步板卡清单 → boards.tsv
├── list-boards.sh          # 合并「TSV + 手写 board.conf」→ CI 矩阵用清单
├── board-resolve.sh        # board id → 完整配置（手写优先，其次 TSV 推导）
├── make-boot-assets.sh     # 打包 bootloader+Image+dtb+modules
├── build-image.sh          # qcow2 rootfs + boot 资产 → 可烧写 .img
├── integrate-iot.sh        # 可选：chroot 内烘焙 Node-RED / Mosquitto / Z2M
└── verify-image.sh         # 上板前的静态校验（纯净镜像 30 项，含 IoT 栈时 +16 项 = 46 项）

.github/workflows/
├── publish-boot-assets.yml # 产出 boot 资产 Release
├── build-openeuler.yml     # 矩阵构建 + 发布纯净镜像
└── build-openeuler-iot.yml # 单板 + 集成安装 IoT 栈
```

**配置优先级**：`boards/<id>/board.conf`（手写，永不覆盖）→ `boards/boards.tsv` + `_template`（自动推导）。

给某块板特调，只建一个文件：

```bash
mkdir -p boards/radxa-rock-4d && cp boards/_template/board.conf boards/radxa-rock-4d/
# 改 CMA=512M、ROOT_UUID 等；其余留空即用推导值
```

---

## 十八个会真的踩到的坑

1–6 是设计上就该处理的，7–14 是纯净构建实跑 CI 时**当场炸出来**的，15–17 是 IoT / 多板阶段补的，18 是**第一次上真机**才炸出来的——写在这里是因为它们极难自查。

### 设计层面

1. **SELinux enforcing → 登录 `Login incorrect`**。openEuler 默认 enforcing，chroot 里改密码直接报 `Authentication token manipulation error`。构建默认写 `selinux=0`，配置文件同步 `SELINUX=disabled` 双保险。

2. **`modules.dep` 必须用目标 rootfs 自己的 `depmod` 生成**。宿主 kmod 版本不同 → `modules.dep.bin` 格式不兼容 → 系统能起、串口能登，但 `lsmod` 空、`ip a` 只有 lo、音频全哑。这就是必须 arm64 原生 runner 的唯一原因。

3. **`/lib/modules` 版本号必须与 `Image` 一字不差**。`verify-image.sh` 会断言目录里**只有一个**模块目录，且与内核版本一致。

4. **官方 qcow2 的 fstab 不能留**。原 `/boot`、`/boot/efi`、xfs 根这些条目会让 systemd 直接进 emergency。构建时整体重写。

5. **不要 initrd**。MMC/SDHCI/EXT4 全 `=y`，rootfs 自带的内核 initramfs 与 vendor 内核无关，留着必炸。生成的 `extlinux.conf` 不含 `initrd` 行。

6. **GitHub Release 单文件上限 2 GiB**。rootfs ~1.5 G → img ~2.8 G → xz ~700 M，压完才上传。

### 实跑暴露（都不是逻辑错误，是环境事实）

7. **`/boot/Image` 是符号链接**。Armbian 里它指向 `vmlinuz-<ver>`，`cp -a` 只存链接本身，目标是悬空的。现象极具误导性：资产只有 25 MiB（正常 ~37 MiB），构建能跑完，装到板上才知道起不来。必须 `cp -aL`。

8. **openEuler 整机镜像根分区在 LVM 里**。布局是 `p1=/boot(ext4)` + `p2=LVM PV`，未 `vgchange -ay` 时 `lsblk` 对 PV 的 FSTYPE 是空的。按 FSTYPE 挑分区永远挑不到，且报错信息只显示两个空类型分区。

9. **`set -o pipefail` + `| head` = 随机失败**。`cat MANIFEST.txt | head -12` 会让 `cat` 收到 SIGPIPE，整条管道非零，`set -e` 直接中止且**没有任何错误输出**。全部改成 `head -12 file` / `awk 'NR==1'`。

10. **`VAR=$(可能失败的函数)` 会吞掉错误分支**。`ROOTDEV=$(find_root_part ...)` 返回非零时，`set -e` 在执行到后面的 `[ -n "$ROOTDEV" ] || die` 之前就退出了，日志里连一行原因都没有。要 `|| true` 后显式判空。

11. **`mount` 挂载点必须预先存在**。`mktemp -d` 只建了父目录，`mount ... "$MNT/ro"` 直接失败。

12. **`sgdisk -i` 的 First sector 不能 `awk -F: '{print $2}'`**。输出是 `First sector: 32768 (at 16.0 MiB)`，去空格后得到 `32768(at16.0MiB)`，后续算术全错。用 `sed -n 's/^First sector: \([0-9]*\).*/\1/p'`。

13. **`sudo` 建的产物属 root，`xz` 改不了属组**。压缩时报 `Cannot set the file group: Operation not permitted`。`build-image.sh` 结束时按 `SUDO_UID/SUDO_GID` 把产物交还调用者。

14. **官方镜像目录带 `openEuler-` 前缀**。是 `/openEuler-24.03-LTS-SP4/virtual_machine_img/aarch64/`，不是 `/24.03-LTS-SP4/...`。

15. **openEuler 的 OS 仓没有 mosquitto**。要装就得加 EPOL 源（`/EPOL/main/$basearch/`）。`integrate-iot.sh` 不硬编码版本，而是从镜像里已有的 `*.repo` 反推主机名与 `openEuler-<ver>` 段拼出来，换 SP 也不会失效。

16. **chroot 里 `localhost:1883` 的 DNS 与 `/etc/resolv.conf` 有关**。官方 qcow2 的 `resolv.conf` 可能指向 systemd-resolved 或是空的，chroot 内 `dnf`/`npm` 会全部域名解析失败。集成前临时写入宿主 nameserver，装完原样还原。

17. **没发 boot 资产就跑 build = 30 秒「假失败」**。日志停在「解析板级配置」，只报 `$BOARD 没有 boot 资产 Release`，很容易误判成拼装脚本坏了。其实是物料没齐：两个 build workflow 只按前缀发现 Release，不会自己下载 Armbian 镜像。先跑 `publish-boot-assets.yml`（或在板上 `--from-dev` 抓取并手动发 Release），再跑 build。现成的可用命令已写在「快速开始」第 1 步和 workflow 的报错提示里。

18. **extlinux.conf 的路径口径 —— 真机唯一一次真失败**。H96 MAX M9 的 vendor U-Boot `2017.09_armbian` 能 `Found /boot/extlinux/extlinux.conf` 并列出 label，但把 conf 里的 `kernel /Image`、`fdt /dtb/rockchip/...` **按分区根解析**，实测：
    ```
    Retrieving file: /Image
    ** File not found /Image **
    Skipping openEuler for failure retrieving kernel
    ```
    内核其实装在 `/boot/Image`。此前 37 项静态校验全过也照样起不来，因为校验只 grep `root=UUID` / `cma=` 这些字符串，从没验证 conf 路径是否指向实体文件。根因是 H96-m9 的 Armbian 镜像**没有 extlinux.conf**，构建走了内置模板，而模板沿用了「相对 `/boot`」的旧口径。

    **修复**：`build-image.sh` 把 kernel/fdt 一律重写为 `/boot/Image` + `/boot/dtb/rockchip/<dtb>`（只继承原 conf 的 `append`）；再用**硬链接**在分区根挂一份 `/Image`、`/dtb/rockchip/<dtb>`，兼容会剥 `/boot` 前缀的 U-Boot 变体。硬链接同 inode、零额外占用，且**不能用软链**——U-Boot 2017.09 的 ext4 驱动不跟随 symlink。`verify-image.sh` 新增 4 项，把 conf 里的 kernel/fdt 路径解析出来断言实体文件存在。

    **更深一层（出处）**：`armbian-custom-builds/boards/h96s/config/boards/h96-m9.csc` 第 19–24 行写明「本板走 `boot.scr + armbianEnv.txt`（无 extlinux）」「不要加 `SRC_EXTLINUX=yes`：自定义 U-Boot defconfig 未显式启用 BOOTMETH_EXTLINUX，强切 extlinux 有不开机风险」；第 150–152 行说明 `boot-rk3576.cmd` 的 bootargs 由 `armbianEnv.txt` 的 `extraboardargs` 拼接（含 `cma=512M`）。也就是说本仓库自己生成 extlinux.conf 属于**改了原厂启动链**。日志证明这块 U-Boot 仍能解析 extlinux，故先按最小改动修路径；若第二轮 `Starting kernel` 之后仍失败，下一步应恢复原厂链路：资产里保留 `boot.scr`/`boot.cmd`/`armbianEnv.txt`，镜像里还原，必要时用 `mkimage` 重编脚本以去掉 `uInitrd`。

    **旧卡不重刷也能验证**（把卡挂到任意 Linux，rootfs 挂 `/mnt`；等价于新镜像里的根兼容层）：
    ```bash
    sudo ln /mnt/boot/Image /mnt/Image
    sudo mkdir -p /mnt/dtb/rockchip
    sudo ln /mnt/boot/dtb/rockchip/rk3576-h96-m9s.dtb /mnt/dtb/rockchip/
    sync && sudo umount /mnt
    ```

19. **`root=UUID=` 在无 initrd 时是死路 —— 真机第二轮真失败**。r10 修好路径后，`/boot/Image`（39 MB）与 DTB 都加载成功、`Starting kernel ...` 后内核完整起来（8 核、HDMI、USB、eMMC 全起），但日志停在：
    ```
    [    4.122012] Kernel command line: root=UUID=5719bdd4-781b-463e-b7b7-7ba8f80fa330 rootwait rw console=ttyS2,1500000n8 cma=256M selinux=disabled cgroup_enable=memory
    [    5.551522] mmcblk2: mmc2:0001 hDEaP3 116 GiB
    [    5.554826]  mmcblk2: p1                       ← 分区和 ext4 都是好的
    [    5.693425] Waiting for root device UUID=5719bdd4-781b-463e-b7b7-7ba8f80fa330...
    [   36.478862] vdd_gpu_s0: disabling             ← 之后只剩 regulator 收尾，不报错、不 panic
    ```
    **根因（有源码佐证）**：`armbian/linux-rockchip@rk-6.1-rkr7.2` 的 `init/do_mounts.c` 里 `name_to_dev_t()` 只有这几条分支：
    ```c
    if (strncmp(name, "PARTUUID=", 9) == 0) return devt_from_partuuid(name + 9);
    if (strncmp(name, "PARTLABEL=", 10) == 0) return devt_from_partlabel(name + 10);
    if (strncmp(name, "/dev/", 5) == 0) return devt_from_devname(name + 5);
    return devt_from_devnum(name);
    ```
    内核**根本不解析 `UUID=`**——那是**文件系统 UUID**（ext4 superblock），要靠 initramfs 里的 udev/blkid 翻译成设备号。我们按设计删掉了 `uInitrd`，却继承了原厂 `armbianEnv.txt` 的 `rootdev=UUID=...` 口径，于是 `ROOT_DEV` 恒为 0，`rootwait` 无限等。上游 `armbian/build@main/config/bootscripts/boot-rk35xx.cmd` 也用 `PARTUUID=${partuuid}`（`part uuid mmc ...`）做 `rootdev` 的标准 fallback，并明确注释「U-Boot 与内核的 mmc 编号可能不同，硬编码 `/dev/mmcblk0p1` 会指向错误设备」；它加载的 `uInitrd` 正是我们删掉的那层。

    **修复**：固定 GPT 分区项 1 的 `UniquePartitionGUID`（`ROOT_PARTUUID`），构建时用 `sgdisk -u "1:<GUID>"` 覆盖 `-n` 生成的随机 GUID 并回读断言；cmdline 改成 `root=PARTUUID=<GUID> rootwait rw rootfstype=ext4`。`fstab` 仍用文件系统 UUID（`blkid` 用户态解析，没问题）——**两个 UUID 是不同字段，不能混用**。`boards/_template/board.conf` 与 `board-resolve.sh`（独立 salt 派生）都补齐该字段，缺合法值直接 `die`。

    **防回归**：`verify-image.sh` 新增 5 项闭环校验 —— GPT 表里实测 GUID = 板级值、loop 设备可见 PARTUUID 一致、conf 反解出的 PARTUUID 与两者一致、禁止出现 `root=UUID=`、必须带 `rootfstype=ext4`。坑 #18 和 #19 是同一类病：**静态校验只 grep 字符串，没把「配置 ↔ 产物实体」对起来**，所以 37/41 项全过照样起不来。

    **同轮三处观察项**（都不是 root 挂载的根因，别混进归因）：
    - `GPT:Primary header thinks Alt. header is not at the end of the disk. GPT:6531071 != 244285439`：镜像只占 3.2 G，刷到 116 GiB eMMC 后 backup GPT 仍在镜像末尾。非阻断——`block/partitions/efi.c` 在主 GPT 有效时照样注册 `p1` 并用 `unique_partition_guid` 填 `info->uuid`（这正是 `PARTUUID=` 能查到的前提）。刷完后 `sgdisk -e /dev/<卡>` 可消掉警告。
    - 板上实测 `printk: console [ttyFIQ0] enabled` / `Registered fiq debugger ttyFIQ0`，8250 只注册 `ttyS4`/`ttyS5`，**这支 vendor 内核没有 `ttyS2`**；内核日志靠 fiq_debugger 自己注册 console 才看得见。两轮日志都正常，故这一轮**不动 cmdline**（改错 baud 解析会连日志都丢）。进系统后若串口没有登录提示符：`systemctl enable --now serial-getty@ttyFIQ0.service`。
    - 原厂 `armbianEnv.txt` 与 `h96-m9.csc` 都是 `cma=512M`（4K60 VPU 解码缓冲需 ≥512M，8 GB 板推荐值），r10 只给了 256M。已对齐 `CMA=512M`，下一轮日志应出现 `cma: Reserved 512 MiB`。

    **旧卡不重刷也能验证**（把卡挂到任意 Linux；等价于新镜像里的改动）：
    ```bash
    DEV=/dev/sdX            # 先 lsblk 确认，别写错盘；eMMC 在板上通常是 /dev/mmcblk2
    PU=78ec7a30-e1b3-4d21-a228-e60e3b63dcee
    sudo sgdisk -e "$DEV"                       # backup GPT 挪到物理末尾
    sudo sgdisk -u "1:$PU" "$DEV"               # 固定分区项 GUID
    sudo sgdisk -i 1 "$DEV" | grep -i 'unique GUID'   # 回读必须等于 $PU
    sudo mount "${DEV}1" /mnt                  # NVMe/mmcblk 用 ${DEV}p1
    sudo sed -i -E "s#root=[^ ]+#root=PARTUUID=$PU#" /mnt/boot/extlinux/extlinux.conf
    grep -q 'rootfstype=' /mnt/boot/extlinux/extlinux.conf || \
      sudo sed -i -E '/^[[:space:]]*append /s#$# rootfstype=ext4#' /mnt/boot/extlinux/extlinux.conf
    sudo sed -i 's/cma=256M/cma=512M/' /mnt/boot/extlinux/extlinux.conf
    grep -E 'append|root=' /mnt/boot/extlinux/extlinux.conf
    sync && sudo umount /mnt
    ```
    改完上板，串口应看到 `VFS: Mounted root (ext4 filesystem)` 而不是 `Waiting for root device`。若只是想换干净镜像，直接刷带 `-r<run>` 的新 Release 更省事。

---

## 不做的事

- 不编内核、不编 U-Boot（用 Armbian 已验证产物）
- 不做桌面环境（headless 优先；GNOME 需要 mesa + panfrost，24.03 的 mesa 版本偏旧）
- 不接管 rkmpp / HT5010 —— 它们在 vendor 内核里，原样继承
- 不做首启自动扩分区（构建时按 `内容 + 12%` 定尺寸，首启无需 `resize2fs`）

配套的逐步 runbook（前置条件 / 每步验证命令 / R1–R3 回滚方案）见 `../docs/openeuler-h96-m9-porting.md`。
