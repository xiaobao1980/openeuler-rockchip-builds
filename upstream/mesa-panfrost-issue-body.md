# src-openeuler/mesa · aarch64 panfrost 需求（issue 正文·纯粘贴版）

标题（issue title，二选一，第一个更贴本包历史命名）：
    [aarch64][RK3576] mesa 未编译 panfrost gallium 驱动，Mali GPU 只能 CPU 软渲染
    请在 aarch64 开启 panfrost gallium 驱动（RK3576 / Mali-G52）

Label：sig/Desktop
类型：feat / 增强

正文如下，整段复制即可（附件请上传 mesa-panfrost-SP4.patch 与 mesa-panfrost-master.patch）：

---

### 1. 一句话结论

openEuler 的 `mesa.spec` 在 `%ifarch %{arm} aarch64` 段里打开了 `vc4` / `v3d` / `kmsro`，
唯独没有 `panfrost`。于是所有用 Mali GPU（panfrost 驱动的 Bifrost 系列）的 aarch64 板子，
`mesa-dri-drivers` 里只有 `swrast_dri.so` / `kms_swrast_dri.so` 加一堆 `kmsro` 哑显示驱动，
没有任何 3D 驱动 —— GLX、EGL、GBM 三条路全部静默回落到 CPU 渲染。

改动只需三段（一个开关 + gallium 列表一处 + `%files` 一行），不新增任何依赖。

### 2. 环境

| 项 | 值 |
| --- | --- |
| 发行版 | openEuler 24.03-LTS-SP4（aarch64） |
| 板卡 | Rockchip RK3576，GPU = Mali-G52 MC3（Bifrost，panfrost 支持列表内） |
| 内核 | vendor 5.10，`CONFIG_DRM_PANFROST=m`，`panfrost.ko` 正常加载，`/dev/dri/renderD128` 存在 |
| mesa | 24.0.3（SP4 分支当前 `Release: 7`） |
| libdrm | 2.4.119-2，`libdrm-devel` 已带 `panfrost_drm.h`（`%{_includedir}/libdrm/*_drm.h`） |

**内核侧完全没问题** —— DRM 节点、`panfrost` 模块、`renderD128` 都在。缺的只是用户态 DRI 驱动。

### 3. 现象

```console
# ls -l /usr/lib64/dri/
swrast_dri.so
kms_swrast_dri.so
rockchip_dri.so          # kmsro 哑驱动：只出画面，没有 GL 加速
...

# dnf provides '*/panfrost_dri.so'
No matches found
```

- `glxinfo -B` → `OpenGL renderer string: llvmpipe / softpipe`（CPU）
- `mpv --vo=gpu --gpu-context=drm`（GBM/DRM 后端）报 `Failed to create GBM surface` /
  无法创建 EGL 上下文，直接退出
- 只能退回纯软件路径 `mpv --vo=drm`：4K60 HEVC 约 **4 fps**，不可用
  （即使 rkmpp 硬解出帧，最后一步缩放/合成仍走 CPU）
- 打开 panfrost 后（我们在板端手工自编验证过）：`GL_RENDERER = Mali-G52 r1 (Panfrost)`，
  同样的 4K60 片子 `--vo=gpu --gpu-context=drm` + `hwdec=rkmpp`（`drm_prime` 零拷贝）稳定 60 fps

### 4. 根因定位（SP4 分支 `mesa.spec` 行号）

| 位置 | 现状 |
| --- | --- |
| L31-35 `%ifarch %{arm} aarch64` | 只定义 `with_vc4` / `with_v3d` / `with_kmsro`，无 `with_panfrost` |
| L338 `-Dgallium-drivers=swrast…` | 列表含 `vc4`/`v3d`/`kmsro`，无 `panfrost` |
| L506-509 `%files dri-drivers` | `vc4_dri.so`、`v3d_dri.so`、`%if with_kmsro` 一组哑驱动，无 `panfrost_dri.so` |

补充说明，避免评审误判：

- `kmsro` **不解决 3D**。它是 kms 系列“哑显示”驱动，只提供 scanout，GL 仍落到 `swrast`。
- 打开 panfrost **不引入任何新依赖**：SP4 spec 里 `with_hardware` 在 aarch64 恒为 1，
  `-Dllvm=enabled`（L360）与 `llvm-devel`（L103）、`libdrm-devel >= 2.4.103`（L88）本来就有。
  panfrost 的 gallium GL 路径也不使用 LLVM 后端 —— 我们实测 `-Dllvm=disabled` 同样编得过、跑得通。
  代价只是多出一个 `panfrost_dri.so`。
- 不涉及 Vulkan：我们不动 `-Dvulkan-drivers`，因此也不触发 Fedora 里 panvk 需要的 clang/SPIRV 那套 BuildRequires。

### 5. 影响面

受影响的是整个 Arm SoC 生态，不只是 RK3576：

- Rockchip RK3576（Mali-G52 MC3）、RK3588/RK3588S（Mali-G510 / Valhall）
- 其它 panfrost 覆盖的 Bifrost/Valhall 平台

被拖低的场景：

- 桌面/GL 应用（UKUI、Xwayland、任何 GTK/Qt GL 路径）
- Wayland 合成器（wlroots / labwc 需要 GBM + EGL 硬件后端）
- 视频播放与硬解零拷贝（mpv gpu-drm + rkmpp `drm_prime`、`gst-gl`）
- `es2_info` / `glmark2` 一类的 GPU 冒烟测试直接失去意义

### 6. 补丁

两个分支各一份，均为 `patch -p1` / `git apply` 可直接套用（已在本机对原始 spec 校验通过）：

- `mesa-panfrost-SP4.patch` —— `openEuler-24.03-LTS-SP4`，`24.0.3-7` → `24.0.3-8`
- `mesa-panfrost-master.patch` —— `master`，`25.0.7-3` → `25.0.7-4`

SP4 改动全文：

```diff
@@ -32,6 +32,7 @@
 %define with_vc4       1
 %define with_v3d       1
 %define with_kmsro     1
+%define with_panfrost  1
 %endif
@@ -335,7 +336,7 @@
 %if 0%{?with_hardware}
-  -Dgallium-drivers=swrast…,%{?with_v3d:,v3d}%{?with_kmsro:,kmsro}%{?with_crocus:,crocus} \
+  -Dgallium-drivers=swrast…,%{?with_v3d:,v3d}%{?with_kmsro:,kmsro}%{?with_panfrost:,panfrost}%{?with_crocus:,crocus} \
@@ -506,6 +507,9 @@
 %if 0%{?with_v3d}
 %{_libdir}/dri/v3d_dri.so
 %endif
+%if 0%{?with_panfrost}
+%{_libdir}/dri/panfrost_dri.so
+%endif
 Release:        7   →   8      （并追加 %changelog 条目）
```

写法与现有 `vc4` / `v3d` 完全同构，也与 Fedora 的 `with_panfrost` 开关一致，无新结构。

### 7. 验证方法

```console
# 1) 包侧
rpmbuild -ba mesa.spec && rpmbuild --rebuild …
ls /usr/lib64/dri/panfrost_dri.so           # 期望存在
# 非 arm 架构应无变化（开关在 %ifarch %{arm} aarch64 内）

# 2) 板侧（RK3576）
reboot 后：
glxinfo -B | grep -i renderer              # 期望 Mali-G52 (Panfrost)
mpv --vo=gpu --gpu-context=drm --hwdec=rkmpp <4K60 片源>   # 期望稳定 60fps
# 回归检查：vc4/v3d/kmsro/swrast 仍在包内，x86_64 包内容不变
```

### 8. 对照：其它发行版怎么做

Fedora 的 `mesa.spec`：

- L51 `%global with_panfrost  1`
- L479 gallium 列表含 `%{?with_panfrost:,panfrost}`
- L671-672 `%if 0%{?with_panfrost}` → `%{_libdir}/dri/panfrost_dri.so`

即“默认打开、开关可控、只多一个驱动对象”，与我们的建议同形。

### 9. 期望

1. 合入 `master`，并回合 `openEuler-24.03-LTS-SP4`（及后续 LTS SP 分支）——
   24.03 是 RK3576 这类嵌入式/边缘设备的实际长期承载版本，只进 master 对我们仍不可用。
2. 若评审认为在 `%ifarch %{arm} aarch64` 内无条件打开过于宽泛，可改为
   `-D with_panfrost 1`（`--with` 构建选项，默认关闭），但希望至少给 Arm SIG / 硬件伙伴一个可用的开关。
3. 欢迎指出更符合 openEuler 打包惯例的写法（如需要独立子包或 drirc 默认配置，我们可再出 v2 补丁）。

### 10. 关联

- 板端实测记录：RK3576 + openEuler 24.03-LTS-SP4，自编 Mesa 24.0.3（panfrost gallium）
  → `GL_RENDERER='Mali-G52 r1 (Panfrost)'`，4K60 `gpu-context=drm` + `hwdec=rkmpp` 稳定。
- 我们当前的绕行方案是在镜像构建里 chroot 自编 Mesa 装到 `/usr/local`，
  并预置 `LIBGL_DRIVERS_PATH=/usr/local/lib64/dri:/usr/lib64/dri`。上游合入后这段会整块删除。
- 同类诉求在本包已有先例并被采纳：Gitee issue `I9GYX8`「master 分支 24.0.3 版本需要开启 zink」、
  `ICHA4R`「缺失 /usr/lib64/dri/zink_dri.so」，最终落到 master changelog
  `24.2.1-2 - add upstream gallivm patch, enable zink for {x86_64,aarch64}`。
  本次请求的形状完全一致：在 `%ifarch %{arm} aarch64` 段里补一个驱动开关。
- 本仓库 issue 均带 `sig/Desktop` 标签，评审对口；SP4 近期维护者包括 pengmeng / 张嘉博 / gaihuiying。

---
