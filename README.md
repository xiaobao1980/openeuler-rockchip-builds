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

> 唯一未验证的是「刷到板上能不能起」—— 需要真机。所有静态校验都过了，但 U-Boot 是否走 extlinux 而非 `boot.scr`，只能上电才知道。

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

推荐在板子上直接抓——这是**原始素材**，保真度最高：

```bash
git clone https://github.com/<you>/openeuler-rockchip-builds && cd openeuler-rockchip-builds
sudo BOARD=h96-m9 ./scripts/make-boot-assets.sh --from-dev /dev/mmcblk0
gh release create boot-h96-m9-6.1.172 out/boot-h96-m9-6.1.172.tar.zst*
```

或者走 CI（`Publish boot assets` workflow），给一个 `.img.xz` 直链即可。

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

串口 `1500000 8N1` 应看到 `U-Boot → extlinux → systemd`。首次登录后 `passwd` 改密码；要用满整卡：

```bash
growpart /dev/mmcblk0 1 && resize2fs /dev/mmcblk0p1
```

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
└── verify-image.sh         # 上板前的静态校验（21 项）

.github/workflows/
├── publish-boot-assets.yml # 产出 boot 资产 Release
└── build-openeuler.yml     # 矩阵构建 + 发布镜像
```

**配置优先级**：`boards/<id>/board.conf`（手写，永不覆盖）→ `boards/boards.tsv` + `_template`（自动推导）。

给某块板特调，只建一个文件：

```bash
mkdir -p boards/radxa-rock-4d && cp boards/_template/board.conf boards/radxa-rock-4d/
# 改 CMA=512M、ROOT_UUID 等；其余留空即用推导值
```

---

## 十四个会真的踩到的坑

前六个是设计上就该处理的，后八个是实跑 CI 时**当场炸出来**的——写在这里是因为它们极难自查。

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

---

## 不做的事

- 不编内核、不编 U-Boot（用 Armbian 已验证产物）
- 不做桌面环境（headless 优先；GNOME 需要 mesa + panfrost，24.03 的 mesa 版本偏旧）
- 不接管 rkmpp / HT5010 —— 它们在 vendor 内核里，原样继承
- 不做首启自动扩分区（构建时按 `内容 + 12%` 定尺寸，首启无需 `resize2fs`）

配套的逐步 runbook（前置条件 / 每步验证命令 / R1–R3 回滚方案）见 `../docs/openeuler-h96-m9-porting.md`。
