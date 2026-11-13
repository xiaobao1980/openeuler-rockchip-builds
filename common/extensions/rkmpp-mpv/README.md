# RKMPP + mpv 硬解栈 — openEuler RPM 打包

把 **Rockchip RK35xx 的 RKMPP 硬件解码栈（mpp + rkrga + ffmpeg-rockchip + mpv rkmpp）**
做成可安装 RPM，供其它 RK35xx 板卡 `dnf install` 直接获得硬解能力，**免去每块板重复编译**。

> 对应 armbian-custom-builds 里的 `common/extensions/rkmpp-mpv/`（那侧产出 `.deb`）。
> 本目录是 openEuler 侧的等价物，产出 `.rpm`。

## 组件与版本

| 组件 | 来源 | 说明 |
|---|---|---|
| mpp | nyanmisaka/mpp `@jellyfin-mpp` | Rockchip MPP 用户态库（硬解核心） |
| rkrga | nyanmisaka/rk-mirrors `@jellyfin-rga` | RGA 缩放/格式转换 |
| ffmpeg-rockchip | nyanmisaka/ffmpeg-rockchip | 带 `h264/hevc/av1/vp9_rkmpp` 解码器的 ffmpeg，隔离装到 `/usr/local/lib/ffmpeg-rkmpp` |
| mpv | 官方 `v0.41.0` | + `mpp.patch`（rkmpp 后端，官方主线不含）+ `vd_lavc-rkmpp-drm.patch`（本仓库独有：RKMPP/DRM 设备类型不匹配时自建解码设备，零拷贝走 `--gpu-context=drm` 必需） |

## 显示后端

mpv 同时编译 **X11 + Wayland + DRM** 三后端（`-Ddrm/x11/wayland=enabled`）。
`vo=gpu` 按会话自动选上下文：

- 有 `DISPLAY` → X11
- 有 `WAYLAND_DISPLAY` → Wayland
- 都没有 → DRM/KMS（headless，直接写屏）

`hwdec=rkmpp` 与显示后端解耦，**三种后端下 rkmpp 硬解都生效**。基础镜像默认 headless，
要桌面播放需另装 Xorg / Wayland 合成器；编进 mpv 的桌面能力不要求打包桌面本身。

## 用法

### 1. 在一台 aarch64 openEuler（24.03-LTS-SP4 验证）上编译并打 RPM

```bash
sudo dnf install -y git cmake meson ninja-build rpm-build
sudo bash build-rkmpp-stack.sh build BUILD_RPM=yes
# 产物：/root/rkmpp-rpms/rkmpp-stack-<ver>-1.<arch>.rpm
```

> 编译这一步**必须在 aarch64 上跑**（macOS/x86 无法编 ARM64 + 链接 openEuler glibc）。
> 一台板编译一次，产出的 RPM 可分发到同发行版同架构的所有板卡。

### 2. 其它板卡直接安装（无需编译）

```bash
sudo dnf install -y ./rkmpp-stack-<ver>-1.aarch64.rpm
# 或
sudo rpm -ivh ./rkmpp-stack-<ver>-1.aarch64.rpm
mpv --hwdec=help 2>&1 | grep rkmpp      # 应看到 rkmpp
```

### 3. 烘焙进 openEuler 镜像（拼装阶段）

```bash
sudo ./integrate-rkmpp.sh <rootfs目录> --rpm=/root/rkmpp-rpms/rkmpp-stack-<ver>-1.aarch64.rpm
# 不传 --rpm 则改为在 rootfs 内联网编译（慢，兜底）
```

## 重要：RPM 是「发行版 + 架构绑定」的

与 deb 同理——二进制由当前系统 glibc 链接、依赖 SONAME 由当前 openEuler 版本决定。
所以：

- **换发行版**（openEuler 24.03 → 其它）→ 必须重编重打；
- **换架构**（aarch64 → 其它）→ 必须重编重打。

每个 RPM 内置 `/usr/local/share/rkmpp-stack/build-info`（记录 ARCH/DISTRO/GLIBC/各组件版本），
供扩展脚本判断「预编译包是否适用目标板」，不匹配应回退源码编译。

## 已知边界

- **8K 高码率瓶颈**：8K HEVC/AV1 100M~150M 实测约 0.07~0.09x（内容秒/墙钟秒），属 RK3576 解码+缩放带宽上限，非软件缺陷。
- **10-bit 必须降位**：10-bit(NV15) 内容经 `vf=lavfi=[scale_rkrga=force_yuv=8bit]` 降为 NV12（Mesa/上游 mpv 不支持 NV15 纹理导入，否则黑屏）；8-bit 内容此滤镜近乎零成本。已写进 `/etc/mpv/mpv.conf`。
- **CMA**：4K/8K 流畅需内核 `cma=512M`（openeuler-rockchip-builds 默认已按 SoC 推导设置）。
- **libplacebo**：mpv 0.40+ 硬依赖 libplacebo >= 6.338.2，openEuler 24.03 SP4 自带满足；若换老系统需升级。
