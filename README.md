# WSL2 Kernel 7.2.8 — Microsoft WSL2 support on Linux 7.2.8

将 **Microsoft WSL2 内核改动**前向移植到 **Linux 7.2.8 stable** 的补丁集与构建脚本。

本仓库**不包含内核源码**，只包含补丁、配置、构建脚本与文档。你需要自行从 kernel.org
获取 Linux 7.2.8 源码（几十 MB，而非完整内核树）。

- 目标版本：`7.2.8`
- 内核发布名：`7.2.8-microsoft-standard-WSL2`
- 基线来源：`linux-7.2.8.tar.xz`
  SHA-256 `12e8d5a973d1ad7c5a5c69882e4022b131ed715db7003fdcd760ddf8c3e51941`
- WSL 改动来源：Microsoft [`WSL2-Linux-Kernel`](https://github.com/microsoft/WSL2-Linux-Kernel)
  分支 `linux-msft-wsl-6.18.y`，tag **`linux-msft-wsl-6.18.40.1`**
  （该分支 HEAD；上一版用的是 `6.18.35.2`，同步记录见
  [docs/PORTING-NOTES.md](docs/PORTING-NOTES.md) 的「Delta 同步」一节）
- 许可：[GPL-2.0-only](LICENSE)（含 [Linux-syscall-note](LICENSES/exceptions/Linux-syscall-note) 例外）

---

## 这个内核做了哪些优化

除了移植 Microsoft 的 WSL2 改动，本版本还针对**文件存储与内存**做了配置层优化，
依据是 Microsoft 官方文档
[跨文件系统的文件存储和性能](https://learn.microsoft.com/zh-cn/windows/wsl/filesystems#file-storage-and-performance-across-file-systems)
以及 Microsoft 自己在新版 WSL 内核里的配置取舍。

实测结论（同一台机器、同一套脚本）：把项目放在 **ext4**（`/home/...`）而不是
用 9P 挂进来的 `/mnt/c`、`/mnt/d`，单文件创建差 **约 100×**、顺序吞吐差 **12~22×**。

| 路径 | 顺序写 | 顺序读 | create | unlink |
|---|---|---|---|---|
| ext4（`/`） | 2.8 GB/s | 6.5 GB/s | 0.02 ms/文件 | 0.76 ms/文件 |
| 9P（`/mnt/d`） | 239 MB/s | 293 MB/s | **2.04 ms/文件** | **3.82 ms/文件** |

**但这条差距不是内核能修的**：`/mnt/*` 走的是 `trans=fd` 的 9P，每请求都要在宿主侧
往返（实测把 `msize` 从 64 KiB 调到 256 KiB 无改善），而宿主没有向 guest 暴露
virtio-9p 设备。完整论证与实测见
[docs/FILESYSTEM-PERFORMANCE.md](docs/FILESYSTEM-PERFORMANCE.md)。

内核配置侧本次实际改动的项目：

- 去掉从 Ubuntu 服务器配置继承的大机器/调试开销：`MAXSMP`、`NR_CPUS` 8192→512、
  `SCHEDSTATS`、`LATENCYTOP`、`SCHED_STACK_END_CHECK`、`SLUB_DEBUG`、`PAGE_POISONING`、`STACKDEPOT`
- 新增压缩内存换页：`ZSWAP`（zstd）+ `ZRAM`（zstd 后端）+ `LRU_GEN`
- 抢占模式改用 `preempt=lazy`（**注意**：`preempt=voluntary` 在 7.2.8 的 x86 上
  会被内核直接拒绝，原因见性能文档 §4.4）

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

从 WSL 6.18 移植到 7.2.8 的全部改动，共 **26 个文件**：

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

## 直接下载预编译内核

不想自己编译的话，可以直接取预编译二进制：

**<https://github.com/ZoeHao2026/wsl-kernel-7.2.8/releases/latest>**

| 附件 | 用途 |
|---|---|
| `bzImage-7.2.8-microsoft-standard-WSL2` | 内核镜像 → `.wslconfig` 的 `kernel=` |
| `modules-7.2.8-microsoft-standard-WSL2.vhdx` | 模块盘（963 个模块）→ `kernelModules=` |
| `System.map-7.2.8-microsoft-standard-WSL2` | 符号表，调试用 |
| `config-7.2.8-microsoft-standard-WSL2` | 构建所用的完整配置 |

校验值见仓库根目录 [`SHA256SUMS`](SHA256SUMS) 与 release 说明页。
下载后按下方「部署到 WSL」配置即可。

### 模块盘为什么是分片的（重要）

release 里的 `modules-7.2.8-microsoft-standard-WSL2.vhdx` **不是单个文件**，而是
**58 个 4 MiB 分片**（`modules-7.2.8-microsoft-standard-WSL2.vhdx.4m00` … `.4m57`），
外加一份 `PART4M-SHA256SUMS`。

原因：本条网络到 `uploads.github.com` 的 POST 会在约 **16 MiB** 处被对端重置。
用 16 MiB 与 40 MiB 两个测试体分别上传，都在 **~16.7 MB** 处断开（`uploaded=` 与
`time=` 两次几乎一致），所以 243 MB 的模块盘无法整文件上传。小于该阈值的附件
（`bzImage` 18 MB、`System.map` 10 MB、`config` 230 KB）都是整文件。

**用脚本重建最省事**（脚本会逐片校验 SHA-256、拼接、再校验整体 SHA-256；
任一步失败即中止，不会留下一个看着正常实则损坏的 VHDX）：

```powershell
# Windows：用 GitHub CLI（能顺带处理私有仓库鉴权）
.\reassemble-modules-vhdx.ps1

# 没有 gh 时走公开直链
.\reassemble-modules-vhdx.ps1 -UseDirectUrl
```

```bash
# Linux / WSL 侧
./reassemble-modules-vhdx.sh
```

重建后的 SHA-256 应为
`89fe1d8d5af13c9a13b4311cc48ee63633ce55594dfcc528ad2520ce63cf0de3`，
大小 `243269632` 字节。这个值已实测确认：把发布出去的分片重新下载拼接，
结果与原始文件**逐字节相同**。

> 如果你把这份内核部署到自己的机器上，建议直接复制现成的模块盘
> （`/usr/lib/modules/7.2.8-microsoft-standard-WSL2` 的布局是**平铺**的，
> 详见 [docs/PORTING-NOTES.md](docs/PORTING-NOTES.md) 的「模块 VHDX 的布局」一节），
> 而不是重新下载分片。

> 模块数由 964 变为 963，不是少了功能：`zsmalloc` 与 `crypto-zstd` 因 `ZSWAP`
> 把它们 `select` 成内建（`=y`）而不是模块，两个 `.ko` 合进了内核镜像。

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

# 2. 应用补丁系列（四个补丁，顺序不可颠倒）
for p in ../patches/series/000*.patch; do patch -p1 --forward < "$p" || exit 1; done

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

或直接使用脚本（会自动放配置、跑 `olddefconfig`、并在结尾校验本次优化项）：

```bash
./scripts/build.sh /path/to/linux-7.2.8
```

打包模块盘（默认 flat 布局，与当前发布件一致；布局细节见
[docs/PORTING-NOTES.md](docs/PORTING-NOTES.md) 的「模块 VHDX 的布局」一节）：

```bash
make modules_install INSTALL_MOD_PATH=./modules-root INSTALL_MOD_STRIP=1
./scripts/gen-modules-vhdx.sh ./modules-root 7.2.8-microsoft-standard-WSL2 \
    ./modules-7.2.8-microsoft-standard-WSL2.vhdx
qemu-img check ./modules-7.2.8-microsoft-standard-WSL2.vhdx
```

复测文件系统性能：

```bash
./scripts/run-fs-bench.sh /tmp/bench-$(uname -r).txt
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
kernel=C:/path/to/bzImage-7.2.8-microsoft-standard-WSL2
kernelModules=C:/path/to/modules-7.2.8-microsoft-standard-WSL2.vhdx
networkingMode=mirrored
dnsTunneling=true
autoProxy=true
firewall=true
```

4. `wsl --shutdown` 后重启发行版

### ⚠️ `.wslconfig` 的路径必须用正斜杠

这是实测踩到的坑，**不是可选的写法偏好**：

```ini
# ❌ 会被拒绝，WSL 静默回退到自带内核
kernel=C:\Users\me\bzImage-7.2.8-microsoft-standard-WSL2
kernelModules=C:\Users\me\modules-7.2.8.vhdx

# ✅ 正确
kernel=C:/Users/me/bzImage-7.2.8-microsoft-standard-WSL2
kernelModules=C:/Users/me/modules-7.2.8.vhdx
```

用反斜杠时 WSL 会报：

```
wsl: 无法解析 C:\Users\me\.wslconfig 第 2 行，忽略该行
wsl: 无法解析 C:\Users\me\.wslconfig 第 3 行，忽略该行
```

然后**回退到微软自带内核**（如 `6.18.33.2-microsoft-standard-WSL2`），而不会报错退出。
如果没注意到 `uname -r` 的变化，会误以为自定义内核"启动成功了"，其实跑的根本不是它。

> 注：微软官方文档示例使用双反斜杠 `C:\\path\\...`。但在实测环境中单反斜杠与
> 双反斜杠都会被拒，只有正斜杠可用——可能是 WSL 2.7.10 在 `mirrored` 网络模式下
> 的解析差异。稳妥做法是**始终用正斜杠**，并在切换后用 `uname -r` 确认。

### 切换后必做的确认

```powershell
wsl --shutdown
wsl -d <发行版> -- uname -r     # 必须显示 7.2.8-microsoft-standard-WSL2
```

如果显示的不是 7.2.8，说明配置被忽略了，内核并未切换。

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
│       ├── 0002-dxgkrnl-use-a-flexible-array-member-for-fence_values.patch
│       ├── 0003-swiotlb-pass-vaddr-to-swiotlb_init_io_tlb_pool.patch
│       └── 0004-wsl2-6.18.40.1-syncfile-leak-fix.patch   delta 同步修复
├── config/
│   ├── config-7.2.8-wsl                 内核配置（本次优化后的权威副本）
│   ├── wsl-securityfs.service           AppArmor securityfs 挂载
│   ├── apparmor-wsl.conf                apparmor.service drop-in
│   ├── zram-wsl.service                 zram(zstd) 压缩交换单元
│   └── 90-wsl-zram-sysctl.conf          swappiness / page-cluster 微调
├── scripts/
│   ├── build.sh                         构建脚本（含优化项自检）
│   ├── gen-modules-vhdx.sh              模块目录 → 模块 VHDX
│   ├── run-fs-bench.sh                  ext4 / 9P 文件系统基准
│   ├── reassemble-modules-vhdx.ps1      重建分片发布的模块盘（Windows）
│   └── reassemble-modules-vhdx.sh       重建分片发布的模块盘（Linux/WSL）
└── docs/
    ├── FILESYSTEM-PERFORMANCE.md        跨文件系统性能实测与本次优化依据
    ├── PORTING-NOTES.md                 移植记录与踩坑
    └── build.log                        完整构建日志
```

---

## 验证状态

### 构建验证 ✅

| 项目 | 结果 |
|---|---|
| 配置收敛 (`olddefconfig`) | ✅ 通过 |
| 完整构建 | ✅ 退出码 0，**0 错误 / 0 警告** |
| 模块 | 963 个 `.ko`，vermagic 一致（`zsmalloc`/`crypto-zstd` 转为内建）|
| 版本串 | `7.2.8-microsoft-standard-WSL2`（无多余后缀）|
| 优化项自检 | ✅ `scripts/build.sh` 结尾逐项校验 11 个配置项，全部 `ok` |

### 真机启动验证 ✅

已在 WSL2（WSL 2.7.10.0 / Windows 11 26200）上实际启动并完成功能测试：

| 项目 | 结果 |
|---|---|
| 内核启动 | ✅ `7.2.8-microsoft-standard-WSL2` |
| 启动日志 | ✅ **无 panic / BUG / oops / Call Trace** |
| systemd | ✅ `running`，**0 个失败单元** |
| AppArmor | ✅ **178 个 profile 加载**（102 个 enforce），securityfs 已挂载 |
| 模块子系统 | ✅ 963 个模块可用；`wireguard`/`zram`/`kvm_intel` 加载与卸载均正常 |
| dxgkrnl | ✅ `hv_vmbus: registering driver dxgkrnl`，`/dev/dxg` 就绪 |
| KVM 嵌套虚拟化 | ✅ `/dev/kvm` 存在，`nested = Y` |
| 网络 | ✅ `mirrored` 模式、DNS 隧道、代理自动注入、HTTPS 出网均正常 |
| 互操作 | ✅ `/mnt/c` (9p)、`powershell.exe` 可用 |
| WSLg | ✅ **真实 GUI 程序（Tk 窗口）创建并正常销毁** |
| 音频 | ✅ `pactl` 连通，`Default Sink: RDPSink` |
| 时间同步 | ✅ 与 Windows 宿主一致（`hv_utils.timesync_implicit=1`）|
| 内存 / swap | ✅ 15 GiB 内存 + 4 GiB 磁盘 swap；另加 1.5 GiB zram(zstd) swap，优先级 100 |
| `NR_CPUS` | ✅ `setup_percpu: NR_CPUS:512`（原 8192），`CPUMASK_OFFSTACK` 已关 |
| `Percpu:` | ✅ 12576 kB → 约 10300–10560 kB |
| 抢占模式 | ✅ `Dynamic Preempt: lazy`，运行时 `full (lazy)`（`preempt=lazy`）|
| zswap / MGLRU | ✅ `CONFIG_ZSWAP=y`（默认 compressor `zstd`）、`LRU_GEN_ENABLED=y` |

详细测试记录见 [docs/PORTING-NOTES.md](docs/PORTING-NOTES.md)，
性能实测与逐项依据见 [docs/FILESYSTEM-PERFORMANCE.md](docs/FILESYSTEM-PERFORMANCE.md)。

### 建议一并启用的 zram 压缩交换

本内核编入了 `ZRAM_BACKEND_ZSTD`，但压缩交换本身要由发行版配置。Ubuntu 26.04
没有预装 `zram-generator`，因此仓库提供的是自包含的 systemd 单元（只依赖内核
自带 zram 模块与 `zramctl`，不引入新软件包）：

```bash
sudo cp config/zram-wsl.service /etc/systemd/system/zram-wsl.service
sudo install -d /etc/sysctl.d
sudo cp config/90-wsl-zram-sysctl.conf /etc/sysctl.d/90-wsl-zram-sysctl.conf
sudo systemctl daemon-reload
sudo systemctl enable --now zram-wsl.service
sudo sysctl --system
zramctl; cat /proc/swaps
```

预期：`zramctl` 显示 `zstd / 1.5G / [SWAP]`，`/proc/swaps` 里 `/dev/zram0`
优先级 **100**（高于磁盘 swap 的 -1，因此内核优先用压缩内存交换）。

对应的 `%USERPROFILE%\.wslconfig` 建议（`kernelCommandLine` 为本次新增）：

```ini
[wsl2]
kernel=C:/path/to/bzImage-7.2.8-microsoft-standard-WSL2
kernelModules=C:/path/to/modules-7.2.8-microsoft-standard-WSL2.vhdx
kernelCommandLine=preempt=lazy
networkingMode=mirrored
dnsTunneling=true
autoProxy=true
firewall=true
```

需要打开 zswap（默认关闭）时把该行换成
`kernelCommandLine=preempt=lazy zswap.enabled=1 zswap.compressor=zstd`。

### 仍需注意

**GPU 硬件加速未启用**，但这与内核无关：

```
/dev/dri             不存在
glxinfo              Accelerated: no (llvmpipe 软件渲染)
dmesg                dxgkio_query_adapter_info: Ioctl failed: -22
```

`dxgkrnl` 已正确注册并工作，是 **Windows 侧显卡驱动过旧**导致无法完成适配器查询。
本机实测：Intel Arc 当前绑定 2024 年的驱动 `32.0.101.5763`，而 DriverStore 中已有
2026 年的 `32.0.101.8991` 未激活。更新 Windows 显卡驱动后即可启用。

参见 [Intel 官方说明](https://www.intel.com/content/www/us/en/support/articles/000094038/graphics.html)
与 [microsoft/WSL#13295](https://github.com/microsoft/WSL/issues/13295)。

**其他未验证项**：仅在此一台机器（Intel Meteor Lake 核显、WSL 2.7.10）上测试过，
未覆盖 NVIDIA/AMD 显卡、Hyper-V 嵌套、其他发行版等场景。

---

## 许可

内核派生代码（`patches/` 中的全部内容）来自 Linux 内核与 Microsoft 的
`WSL2-Linux-Kernel` 仓库，均为 **GPL-2.0-only**，并遵循内核的
[Linux-syscall-note](LICENSES/exceptions/Linux-syscall-note) 例外（适用于 uapi 头文件）。

本仓库的构建脚本与文档由本项目作者编写，同样以 GPL-2.0-only 发布，以便整体一致。

Linux 是 Linus Torvalds 的注册商标。
