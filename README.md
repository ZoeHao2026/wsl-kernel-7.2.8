# WSL2 Kernel 7.2.8 — Microsoft WSL2 support on Linux 7.2.8

将 **Microsoft WSL2 内核改动**前向移植到 **Linux 7.2.8 stable** 的补丁集与构建脚本。

本仓库**不包含内核源码**，只包含补丁、配置、构建脚本与文档。你需要自行从 kernel.org
获取 Linux 7.2.8 源码（几十 MB，而非完整内核树）。

- 目标版本：`7.2.8`
- 内核发布名：`7.2.8-microsoft-standard-WSL2`
- 基线来源：`linux-7.2.8.tar.xz`
  SHA-256 `12e8d5a973d1ad7c5a5c69882e4022b131ed715db7003fdcd760ddf8c3e51941`
- WSL 改动来源：Microsoft [`WSL2-Linux-Kernel`](https://github.com/microsoft/WSL2-Linux-Kernel)
  分支 `linux-msft-wsl-6.18.y`，tag `linux-msft-wsl-6.18.35.2`
- 许可：[GPL-2.0-only](LICENSE)（含 [Linux-syscall-note](LICENSES/exceptions/Linux-syscall-note) 例外）

---

## 为什么需要这个项目

Microsoft 的 WSL2 内核补丁**只针对 6.18 分支**维护，官方仓库没有 7.x 版本。如果你想要
7.2 稳定版的好处（更新的硬件支持、安全修复、更长的维护周期），就必须自己做前向移植。

本仓库把这件事做完了，并且把移植过程中踩到的坑记录在
[docs/PORTING-NOTES.md](docs/PORTING-NOTES.md) 里。

### 与 7.1.x 方案的区别

| | 7.1.x 系列 | 本项目 (7.2.8) |
|---|---|---|
| 支持状态 | **已于 2026-09-02 EOL** | 当前 stable，持续维护 |
| 安全更新 | 不再提供 | 持续提供 |
| WSL 改动移植 | 同系列增量，冲突极少 | 跨系列前向移植，需处理冲突 |
| 已修复缺陷 | 依赖事后补丁 | 已内联修复（见下） |

---

## 移植内容

从 WSL 6.18 移植到 7.2.8 的全部改动，共 **25 个文件**（15 个新增 + 10 个修改）：

### 新增：dxgkrnl 驱动（15 个文件）

GPU 半虚拟化驱动，WSLg 与 GPU 计算的基础：

```
drivers/hv/dxgkrnl/
├── Kconfig, Makefile
├── dxgmodule.c          模块初始化
├── dxgvmbus.c/.h        VMBus 通信
├── dxgadapter.c         适配器
├── dxgprocess.c         进程
├── dxgsyncfile.c/.h     同步文件
├── hmgr.c/.h            句柄管理
├── ioctl.c              ioctl 接口
└── misc.c/.h            杂项
```

### 新增：用户态 ABI

- `include/uapi/misc/d3dkmthk.h` — D3DKMT/DXGK 用户态接口（带 Linux-syscall-note 例外）

### 修改：上游既有代码（10 个文件）

| 文件 | 改动内容 |
|---|---|
| `drivers/hv/Kconfig` | 引入 `dxgkrnl/Kconfig`；`HYPERV_TIMER` 不再限定 X86 |
| `drivers/hv/Makefile` | 接线 `obj-$(CONFIG_DXGKRNL) += dxgkrnl/` |
| `include/linux/hyperv.h` | DXGK 全局/每 vGPU 通道 GUID |
| `arch/x86/kernel/cpu/mshyperv.c` | 宿主 build < 22621 时禁用 TSC invariant（规避休眠后 TSC 变慢的宿主缺陷） |
| `drivers/clocksource/hyperv_timer.c` | ARM64 条件编译分支 |
| `kernel/dma/swiotlb.c` | 新增 `swiotlb_create_pool()` 导出接口 |
| `include/linux/swiotlb.h` | 上述接口声明 |
| `drivers/pci/controller/pci-hyperv.c` | hv_pci 专用 swiotlb 池 + `hv_pci_swiotlb=` 引导参数 + sysfs 导出 |
| `fs/fuse/virtio_fs.c` | 用 virtio 最大 DMA 尺寸约束 `max_pages_limit` |

---

## 已修复的缺陷

移植过程中发现并修复的**真实缺陷**（不只是移植适配）：

### 1. dxgkrnl 柔性数组 / FORTIFY 缺陷 — commit `f34bd6c`

`dxgkvmbus.h` 把变长尾部数组声明为固定长度：

```c
u64 fence_values[1];        /* 改为 fence_values[] */
```

该数组实际按 `object_count` 个元素使用，其后紧跟 `object_count` 个 handle。
固定长度 1 会让结构体看起来是定长的、且最后一个成员跨越了变长尾部，
被 `FORTIFY_SOURCE` 判定为 field-spanning write。同时使 `sizeof` 计算失真：

```c
/* 错误：柔性数组头里并没有内嵌 fence 槽位，不该减 */
u32 cmd_size = object_size + fence_size - sizeof(u64) + sizeof(...);
```

改为柔性数组成员，并同步修正 `cmd_size` 与指针基址（`&command[1]`）。
缓冲区尺寸不变，VMBus 线格式与宿主契约不受影响。

### 2. 移植冲突的手工补正 — commit `ff97c62`

`patch --forward` 在 hunk 失败时仍会返回非 0 但**继续处理后续文件**。若构建脚本
未检查它的退出码，补丁会**静默丢失**。本次移植中有两处因此需要在 7.2.8 上手写补正：

- `drivers/hv/Makefile`：补上 `obj-$(CONFIG_DXGKRNL) += dxgkrnl/`。
  缺这一行，15 个驱动文件**完全不会被编译**，而构建却"成功"。
- `arch/x86/kernel/cpu/mshyperv.c`：补上 `version` / `build` 两个局部变量声明。
  上层 TSC 检查代码已在引用它们，缺失会直接编译失败。

### 3. 上游已合并、无需再打的部分

`fs/fuse/file.c` 的 `FUSE_IS_DAX` 修复（DAX inode 释放时允许阻塞）**在 7.2.8 中
已由上游包含**，WSL 补丁的对应 hunk 会被判定为 "previously applied" 而跳过。
这不是缺陷，保留为记录以免后来者困惑。

---

## 构建

### 依赖

```bash
sudo apt install build-essential flex bison bc libelf-dev libssl-dev \
                 dwarves zstd cpio rsync xz-utils
```

### 步骤

```bash
# 1. 获取源码并校验
curl -LO https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.8.tar.xz
echo "12e8d5a973d1ad7c5a5c69882e4022b131ed715db7003fdcd760ddf8c3e51941  linux-7.2.8.tar.xz" | sha256sum -c -
tar xf linux-7.2.8.tar.xz
cd linux-7.2.8

# 2. 应用补丁系列（两个补丁，顺序不可颠倒）
patch -p1 < ../patches/series/0001-port-Microsoft-WSL2-6.18-support-onto-Linux-7.2.8.patch
patch -p1 < ../patches/series/0002-dxgkrnl-use-a-flexible-array-member-for-fence_values.patch

# 3. 放置配置
cp ../config/config-7.2.8-wsl .config
make olddefconfig

# 4. 构建（关键：必须导出 LOCALVERSION，见下节）
export LOCALVERSION=""
make -j"$(nproc)"

# 5. 安装模块（按需）
make modules_install INSTALL_MOD_PATH=./modules-root INSTALL_MOD_STRIP=1

# 6. 取出内核镜像
#    arch/x86/boot/bzImage
```

> 也提供了一份**合并补丁** `patches/0001-wsl2-6.18-port-to-7.2.8.patch`（含全部改动），
> 适合一次性应用；`patches/series/` 下的分层版本便于逐个审阅改动。

或直接使用脚本：

```bash
./scripts/build.sh /path/to/linux-7.2.8
```

### ⚠️ 关于 `LOCALVERSION=`

**这一步不能省。** `scripts/setlocalversion` 在「`LOCALVERSION` 环境变量未设置」且
「有匹配的 tag 命中 HEAD」时会从其 `--short` 分支输出一个 `+`，导致内核名变成
`7.2.8-microsoft-standard-WSL2+`。

`CONFIG_LOCALVERSION` **无法**抑制它——只有设置 `LOCALVERSION` 环境变量才会跳过该
分支。传空串即可：名称由 `CONFIG_LOCALVERSION` 提供，且不追加任何后缀。

（依据：`scripts/setlocalversion` 第 115–121 行与第 201 行。）

---

## 部署到 WSL

1. 把 `arch/x86/boot/bzImage` 放到一个 Windows 可访问路径
2. 生成模块 VHDX（参考 `scripts/`，需要 `Microsoft/scripts/gen_modules_vhdx.sh`），或用
   `INSTALL_MOD_PATH` 输出目录配合相应工具
3. 编辑 `%USERPROFILE%\.wslconfig`：

```ini
[wsl2]
kernel=C:\\path\\to\\bzImage-7.2.8
kernelModules=C:\\path\\to\\modules-7.2.8.vhdx
networkingMode=mirrored
dnsTunneling=true
autoProxy=true
firewall=true
```

4. `wsl --shutdown` 后重启发行版

### 配套的 AppArmor 设置

本内核把 AppArmor 调整为第一个 legacy major LSM。发行版**必须**在
`apparmor.service` 之前挂载 securityfs，否则：

- `securityfs` 未挂载，`aa-status` 报 `apparmor filesystem is not mounted`
- AppArmor profile 完全不加载
- 依赖用户会话的服务（如 `user@1000.service`）会失败，systemd 变 `degraded`

本仓库提供现成文件：

- [`config/wsl-securityfs.service`](config/wsl-securityfs.service) — 挂载 securityfs
- [`config/apparmor-wsl.conf`](config/apparmor-wsl.conf) — 让 apparmor.service 依赖它

安装：

```bash
sudo cp config/wsl-securityfs.service /etc/systemd/system/
sudo mkdir -p /etc/systemd/system/apparmor.service.d
sudo cp config/apparmor-wsl.conf /etc/systemd/system/apparmor.service.d/
sudo systemctl daemon-reload
sudo systemctl enable --now wsl-securityfs.service apparmor.service
```

同时建议屏蔽 WSL 中无意义的 getty（无本地 VT 控制台，必然失败）：

```bash
sudo systemctl mask getty@tty1.service
```

验证：

```bash
systemctl is-system-running              # 期望 running
findmnt /sys/kernel/security             # 期望 securityfs
systemctl is-active apparmor             # 期望 active
aa-status | head -3                      # 期望列出已加载 profile
```

---

## 仓库结构

```
.
├── LICENSE                              GPL-2.0 全文
├── COPYING                              内核许可说明 (SPDX)
├── LICENSES/exceptions/                 Linux-syscall-note 例外
├── patches/
│   ├── 0001-wsl2-6.18-port-to-7.2.8.patch   合并补丁（含全部改动）
│   └── series/
│       ├── 0001-port-Microsoft-WSL2-6.18-support-onto-Linux-7.2.8.patch
│       └── 0002-dxgkrnl-use-a-flexible-array-member-for-fence_values.patch
├── config/
│   ├── config-7.2.8-wsl                 内核配置
│   ├── wsl-securityfs.service           AppArmor securityfs 挂载
│   └── apparmor-wsl.conf                apparmor.service drop-in
├── scripts/
│   └── build.sh                         构建脚本
└── docs/
    ├── PORTING-NOTES.md                 移植记录与踩坑
    └── build.log                        完整构建日志
```

---

## 验证状态

| 项目 | 状态 |
|---|---|
| 配置收敛 (`olddefconfig`) | ✅ 通过 |
| 完整构建 | 见 [docs/PORTING-NOTES.md](docs/PORTING-NOTES.md) |
| dxgkrnl 编入内核 | 见 PORTING-NOTES |
| 真机启动 | 未验证（需自行在 WSL 中测试） |

> **注意**：本移植经过构建验证，但**未在真实 WSL 上启动测试**。GPU 直通能否工作
> 取决于 Windows 侧显卡驱动（需要支持 D3D12 的较新驱动），与内核无关。

---

## 许可

内核派生代码（`patches/` 中的全部内容）来自 Linux 内核与 Microsoft 的
`WSL2-Linux-Kernel` 仓库，均为 **GPL-2.0-only**，并遵循内核的
[Linux-syscall-note](LICENSES/exceptions/Linux-syscall-note) 例外（适用于 uapi 头文件）。

本仓库的构建脚本与文档由本项目作者编写，同样以 GPL-2.0-only 发布，以便整体一致。

Linux 是 Linus Torvalds 的注册商标。
