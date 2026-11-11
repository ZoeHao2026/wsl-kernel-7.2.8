# WSL2 Kernel 7.3.4 — Microsoft WSL2 support on Linux 7.3.4

将 **Microsoft WSL2 内核改动**前向移植到 **Linux 7.3.4 stable** 的补丁集、
配置、构建脚本与一键部署。

> 仓库名 `wsl-kernel-7.2.8` 是 7.2.8 时期的历史命名；从 `v7.3.4-wsl-kernel.1`
> 起，`releases/latest` 指向 7.3.4。旧 release 与旧 tag 原样保留，可随时回滚。

- 目标版本：`7.3.4`
- 内核发布名：`7.3.4-microsoft-standard-WSL2`
- 上游基线：`linux-7.3.4.tar.xz`
  SHA-256 `b11b6df8295e8e991ff040b71aaa4994a8b55caa23b6b092907f195b5840fd1f`
- WSL 改动来源：Microsoft [`WSL2-Linux-Kernel`](https://github.com/microsoft/WSL2-Linux-Kernel)
  分支 `linux-msft-wsl-6.18.y`，tag **`linux-msft-wsl-6.18.58.1`**
  （commit `a9891719…`，2026-10-27；上一版是 `6.18.40.1`）
- 许可：[GPL-2.0-only](LICENSE)（含 [Linux-syscall-note](LICENSES/exceptions/Linux-syscall-note) 例外）

---

## 这一版做了什么

### 1. 内核更新

- Linux `7.2.8` → **`7.3.4`**（2026-11-10 发布，当前 stable；7.4 尚在 rc）
- WSL delta `6.18.40.1` → **`6.18.58.1`**：
  - `dxgkrnl` 同步到 58.1，包含 **native fence sharing**（VMBus 接口 44 → 46）、
    `dxgsyncfile` 引用泄漏修复、若干 ioctl/适配器修复；
  - `arm64` Hyper-V synthetic clocks/timers 的 `hyperv_timer.c`/Kconfig 部分；
  - `virtio-fs` 的 DMA 上限修复保持；
  - 6.18.58 stable 的上游修复随基线进入。
- 重新移植尺度：**25 个文件**（15 个 `drivers/hv/dxgkrnl/*` + UAPI 头 + 9 个上游文件），
  `patch` 在 7.3.4 上**零 reject**，只做了 offset 适配；详见
  [docs/PORTING-NOTES.md](docs/PORTING-NOTES.md) 的「7.3.4 移植记录」一节。

### 2. 修复

- **7.3 新增的 VPCI DMA 静默失败点**：7.3 的 `swiotlb` 用每池的 `mem->cc_shared`
  判断 DMA 是否可用；移植过来的 `swiotlb_create_pool()` 原先没有设置它，在
  paravisor/CC 客户机上 VPCI DMA 会返回 `DMA_MAPPING_ERROR`。本版补上了与
  `swiotlb_create_default_pools()` 一致的设置（`cc_platform_has(CC_ATTR_MEM_ENCRYPT)`
  时 `cc_shared = true`），见 `patches/7.3.4/0002`。
- **zram 反复重置**：旧单元挂到 `swap.target`，WSL 每个会话结束都会停它，
  导致 `swapoff`/`reset`，下一次 `wsl` 命令再重建（实测 dmesg 里出现 48 次
  `zram: Removed device`/`Added device` 循环）。新版本改用幂等脚本
  `/usr/local/libexec/zram-wsl-setup`，挂在 `multi-user.target`，并且**多发行版安全**：
  只要内核里已有任一 zram swap 就什么都不做，不再无条件 reset 共享的 `/dev/zram0`。
- **`/tmp/.X11-unix` 挂载叠加**：修复脚本现在会先收掉叠加的多余挂载，再重建
  一层；修复前 `mount` 表里会出现 2 层 `/tmp/.X11-unix`，关机时容易卡住。
- **AppArmor 冷启动条件**：`apparmor.service` 自带 `ConditionSecurity=apparmor`，
  会在 securityfs 挂载前求值；本版把 `wsl-securityfs.service` + drop-in 纳入
  一键安装，避免 178/179 个 profile 在部分冷启动中被跳过。
- **构建脚本**：7.2.8 时期的 `make O=` 外部输出目录会因为源码树不干净失败；
  新 `scripts/build.sh` 改为已验证的树内构建，并在结尾逐项校验优化配置。
- **`.wslconfig` 垃圾目录**：清掉了历史坏引用生成的
  `C:\Users\<user>\wsl-kernel\' -SkipKernel','-DryRun'`。

### 3. 优化（配置层）

配置基线改为 Microsoft `6.18.58.1` 的 `arch/x86/configs/config-wsl`，再叠加本仓库
已验证的调优项。与 7.2.8 版相比，主要变化：

| 配置 | 7.3.4 | 说明 |
|---|---|---|
| `CONFIG_XEN` | 关 | 从 7.2.8 完整配置继承来的，WSL 用不到，去掉后镜像更小 |
| `CONFIG_DEBUG_LIST` / `DEBUG_SG` | 关 | 对齐 Microsoft 新配置，去掉热路径调试检查 |
| `CONFIG_KFENCE` | 开 | Microsoft 默认；采样开销很低，保留以便抓驱动 bug |
| `CONFIG_PREEMPT_NONE` + `PREEMPT_DYNAMIC` | 是 | 启动参数 `preempt=lazy` 仍然生效（`Dynamic Preempt: lazy`） |
| `CONFIG_ZRAM_DEF_COMP` | `"zstd"` | 审计发现旧配置是 `lzo-rle`，与服务显式参数不一致 |
| `CONFIG_NTFS3_FS` | `=m` | 审计标记为缺失；用于挂载 NTFS 镜像/移动盘（`/mnt/c` 走 9P，不依赖它） |
| `CONFIG_SQUASHFS_ZSTD` / `EROFS_FS_ZIP_ZSTD` | `=y` | snap/AppImage/只读镜像需要 |
| `CONFIG_ZSWAP` | `=y`，默认关 | 保留能力，但**不要和 zram 同时启用**（会双重压缩） |
| `CONFIG_LRU_GEN` / `LRU_GEN_ENABLED` | `=y` | 内存偏紧时回收效率更好 |
| `CONFIG_MAXSMP` / `NR_CPUS` | 关 / 512 | 对齐 Microsoft |
| `CONFIG_SLUB_DEBUG` / `PAGE_POISONING` / `SCHEDSTATS` / `LATENCYTOP` | 关 | 上一版已验证的收敛项 |
| `CONFIG_INIT_ON_ALLOC_DEFAULT_ON` / `FORTIFY_SOURCE` / `HARDENED_USERCOPY` | 保持 | 不牺牲这些默认 |
| `CONFIG_DEBUG_INFO_BTF` | 保持 | eBPF 工具链前提 |
| `CONFIG_DEFAULT_SECURITY_APPARMOR` | `=y` | Ubuntu 26.04 依赖 AppArmor；LSM 顺序 apparmor 在 selinux 前 |

构建结果：`bzImage` **16,745,472 B**（7.2.8 为 18,166,272 B），
`Percpu:` **11,616 kB**（7.2.8 基线 11,712 kB），
`Memory: 24,586,852K/25,164,412K available`。

---

## 直接下载预编译内核

**<https://github.com/ZoeHao2026/wsl-kernel-7.2.8/releases/latest>**

| 附件 | 大小 | 用途 |
|---|---|---|
| `bzImage-7.3.4-microsoft-standard-WSL2` | 16,745,472 B | 内核镜像 → `.wslconfig` 的 `kernel=` |
| `modules-7.3.4-microsoft-standard-WSL2.vhdx`（34 个分片） | 142,606,336 B | 模块盘（746 个模块）→ `kernelModules=` |
| `System.map-7.3.4-microsoft-standard-WSL2` | 9,847,930 B | 符号表，调试用 |
| `config-7.3.4-microsoft-standard-WSL2` | 200,019 B | 构建所用的完整配置 |
| `PART4M-SHA256SUMS` | — | 34 个分片的逐片校验值 |
| `SHA256SUMS` | — | 上述产物的整文件校验值 |
| `wsl-kernel-deploy.zip` / `.tar.gz` | — | 一键部署包 |
| `reassemble-modules-vhdx.ps1` / `.sh` | — | 从分片重建模块盘 |
| `RELEASE-NOTES.md` | — | 本版发布说明 |

### 校验值 (SHA-256)

```
76364b56fb7555c01a8a790a01dcfb2c1b20a9e9540629e29dbde89db868dc59  bzImage-7.3.4-microsoft-standard-WSL2
cfc89a93ffa768210e4d191cb5734a962b9955f2a787a81be4e3aeb8ba1cb7aa  System.map-7.3.4-microsoft-standard-WSL2
f9233c002b5d3a67984a7b55cdf75af9cb32cbf6730f5852ca250a14a6dcf71e  config-7.3.4-microsoft-standard-WSL2
369502e174626874362b06973cdcf8a07a110d7f6f38413e460ca3c3433f61bd  modules-7.3.4-microsoft-standard-WSL2.vhdx（拼接后）
```

### 模块盘为什么是分片的

release 里的模块盘是 **34 个 4 MiB 分片**
（`modules-7.3.4-microsoft-standard-WSL2.vhdx.4m00` … `.4m33`），外加
`PART4M-SHA256SUMS`。原因：本条网络到 `uploads.github.com` 的 POST 会在约
**16 MiB** 处被对端重置（16 MiB 与 40 MiB 的测试体都在 ~16.7 MB 处断开），
136 MB 的模块盘无法整文件上传。

用脚本重建（逐片校验 → 拼接 → 再校验整体 SHA-256，任一步失败即中止）：

```powershell
# Windows：用 GitHub CLI（能顺带处理私有仓库鉴权）
.\reassemble-modules-vhdx.ps1

# 没有 gh 时走公开直链
.\reassemble-modules-vhdx.ps1 -UseDirectUrl
```

```bash
./reassemble-modules-vhdx.sh
```

重建结果应为 **142,606,336 字节**，
SHA-256 `369502e174626874362b06973cdcf8a07a110d7f6f38413e460ca3c3433f61bd`。
这个结论是实测的：把发布出去的分片重新下载拼接，与原始模块盘逐字节相同。

> 模块数 746（7.2.8 版 963）不是少了功能：新配置对齐 Microsoft 6.18.58.1，
> 关掉了大量 WSL 用不到的 DRM/网卡/声卡驱动；同时 `ntfs3`、`squashfs zstd`、
> `erofs zstd` 是新增的。`zsmalloc`/`crypto-zstd` 仍是内建（被 ZSWAP select）。

---

## 一行命令安装

### Windows（装内核 + 环境修复）

```powershell
irm https://github.com/ZoeHao2026/wsl-kernel-7.2.8/releases/latest/download/bootstrap.ps1 | iex
```

它会自动：下载部署包 → 校验是真正的压缩包 → 解包 → 从 release 取内核产物并
**逐个校验 SHA-256** → 备份并更新 `.wslconfig` → 在 WSL 里装环境修复 → 清理。

**装完必须重启 WSL，并核对 `uname -v`（构建时间）：**

```powershell
wsl --shutdown
wsl -d Ubuntu-26.04 -- uname -r    # 期望 7.3.4-microsoft-standard-WSL2
wsl -d Ubuntu-26.04 -- uname -v    # 期望构建时间与部署前不同
```

> 为什么不能只看 `uname -r`：WSL 会复用内存里已有的虚拟机实例。只替换
> `bzImage` 而不真正重启时，版本号可能给出误导性的"成功"，实际没换内核。

### WSL 侧（只装环境修复，不动内核）

```bash
curl -fsSL https://github.com/ZoeHao2026/wsl-kernel-7.2.8/releases/latest/download/bootstrap.sh \
  | sudo bash
```

### 常用变体

```powershell
# 只装环境修复，不碰内核
& ([scriptblock]::Create((irm https://github.com/ZoeHao2026/wsl-kernel-7.2.8/releases/latest/download/bootstrap.ps1))) -SkipKernel

# 只看计划，不改任何东西
& ([scriptblock]::Create((irm https://github.com/ZoeHao2026/wsl-kernel-7.2.8/releases/latest/download/bootstrap.ps1))) -SkipKernel -DryRun

# 用本地已构建/已下载的产物，不走网络
& ([scriptblock]::Create((irm https://github.com/ZoeHao2026/wsl-kernel-7.2.8/releases/latest/download/bootstrap.ps1))) -KernelDir C:\path\to\artifacts
```

```bash
# 查看状态 / 卸载（卸载只删它自己装的文件）
curl -fsSL .../releases/latest/download/bootstrap.sh | sudo bash -s -- --status
curl -fsSL .../releases/latest/download/bootstrap.sh | sudo bash -s -- --uninstall
```

---

## 构建

### 依赖

```bash
sudo apt install build-essential flex bison bc libelf-dev libssl-dev \
                 dwarves zstd cpio rsync xz-utils qemu-utils e2fsprogs
```

### 步骤

```bash
# 1. 获取源码并校验
curl -LO https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.4.tar.xz
echo "b11b6df8295e8e991ff040b71aaa4994a8b55caa23b6b092907f195b5840fd1f  linux-7.3.4.tar.xz" | sha256sum -c -
tar xf linux-7.3.4.tar.xz
cd linux-7.3.4

# 2. 应用补丁（顺序不可颠倒）
for p in ../patches/7.3.4/000*.patch; do patch -p1 --forward < "$p" || exit 1; done

# 3. 放置配置
cp ../config/config-7.3.4-wsl .config
make olddefconfig

# 4. 构建（关键：必须 export LOCALVERSION）
export LOCALVERSION=""
make -j"$(nproc)"
make -j"$(nproc)" modules

# 5. 安装模块（按需）
make modules_install INSTALL_MOD_PATH=./modules-root INSTALL_MOD_STRIP=1
```

> 也提供合并补丁 `patches/0001-wsl2-6.18.58-port-to-7.3.4.patch`（含全部改动），
> 适合一次性应用；`patches/7.3.4/series` 下的分层版本便于逐个审阅。

或直接使用脚本（自动放配置、olddefconfig、构建，并在结尾校验优化项）：

```bash
./scripts/build.sh /path/to/linux-7.3.4
```

打包模块盘（flat 布局，与发布件一致）：

```bash
./scripts/gen-modules-vhdx.sh ./modules-root 7.3.4-microsoft-standard-WSL2 \
    ./modules-7.3.4-microsoft-standard-WSL2.vhdx
qemu-img check ./modules-7.3.4-microsoft-standard-WSL2.vhdx
```

复测文件系统性能 / 采集验证：

```bash
./scripts/run-fs-bench.sh /tmp/bench-$(uname -r).txt
sudo ./scripts/validate-wsl-kernel.sh /tmp/validate-$(uname -r).txt
```

### ⚠️ 关于 `LOCALVERSION=`

`scripts/setlocalversion` 在「`LOCALVERSION` 环境变量未设置」且「有匹配的 tag
命中 HEAD」时会从其 `--short` 分支输出一个 `+`，导致内核名变成
`7.3.4-microsoft-standard-WSL2+`。`CONFIG_LOCALVERSION` **无法**抑制它——只有
设置 `LOCALVERSION` 环境变量才会跳过该分支。传空串即可。

---

## 部署到 WSL

1. 把 `bzImage` 放到一个 Windows 可访问路径
2. 用 `scripts/gen-modules-vhdx.sh` 生成模块 VHDX（或直接下载发布件）
3. 编辑 `%USERPROFILE%\.wslconfig`：

```ini
[wsl2]
memory=24GB
kernel=C:/Users/you/wsl-kernel/7.3.4/bzImage-7.3.4-microsoft-standard-WSL2
kernelModules=C:/Users/you/wsl-kernel/7.3.4/modules-7.3.4-microsoft-standard-WSL2.vhdx
kernelCommandLine=preempt=lazy
networkingMode=mirrored
dnsTunneling=true
autoProxy=true
firewall=true
swap=8GB
swapFile=D:\\WSL\\swap.vhdx

[experimental]
autoMemoryReclaim=gradual
```

4. `wsl --shutdown` 后重启，`uname -v` 确认构建时间变化

### ⚠️ `.wslconfig` 的路径必须用正斜杠

双反斜杠/单反斜杠路径实测会被 WSL 拒绝并**静默回退到微软自带内核**。
排查时留意 `uname -r`；详见 [docs/PORTING-NOTES.md](docs/PORTING-NOTES.md)。

### 配套的 AppArmor 设置

一键安装已经包含 `wsl-securityfs.service` 与 `apparmor.service` drop-in。
手动安装方式：

```bash
sudo cp config/wsl-securityfs.service /etc/systemd/system/
sudo mkdir -p /etc/systemd/system/apparmor.service.d
sudo cp deploy/wsl-env/assets/apparmor-20-wsl-boot.conf /etc/systemd/system/apparmor.service.d/20-wsl-boot.conf
sudo systemctl daemon-reload
sudo systemctl enable --now wsl-securityfs.service
sudo systemctl restart apparmor.service
```

验证：

```bash
systemctl is-system-running              # 期望 running
findmnt /sys/kernel/security             # 期望 securityfs
aa-status | head -3                      # 期望列出已加载 profile
```

---

## 仓库结构

```
.
├── config/
│   ├── config-7.3.4-wsl                 内核配置（本次优化后的权威副本）
│   ├── wsl-securityfs.service           AppArmor securityfs 挂载
│   ├── apparmor-wsl.conf / apparmor-wsl-boot.conf
│   ├── zram-wsl.service                 zram(zstd) 压缩交换单元
│   └── 90-wsl-zram-sysctl.conf          swappiness / page-cluster 微调
├── patches/
│   ├── 0001-wsl2-6.18.58-port-to-7.3.4.patch  合并补丁
│   └── 7.3.4/
│       ├── 0001-port-Microsoft-WSL2-6.18.58-onto-Linux-7.3.4.patch
│       ├── 0002-swiotlb-pass-vaddr-and-set-cc_shared.patch
│       └── series
├── deploy/
│   ├── bootstrap.ps1 / bootstrap.sh     一条命令入口
│   ├── install.ps1                      Windows 侧安装器
│   └── wsl-env/
│       ├── install.sh                   WSL 侧安装器（幂等/可卸载/--dry-run）
│       └── assets/                      被安装的文件
├── scripts/
│   ├── build.sh                         树内构建 + 配置自检
│   ├── gen-modules-vhdx.sh              模块目录 → 模块 VHDX
│   ├── run-fs-bench.sh                  ext4 / 9P 基准
│   ├── validate-wsl-kernel.sh           一次性采集验证结果
│   └── reassemble-modules-vhdx.ps1/.sh  从分片重建模块盘
├── docs/
│   ├── PORTING-NOTES.md                 移植记录（含 7.3.4 一节）
│   ├── FILESYSTEM-PERFORMANCE.md        跨文件系统性能与配置依据
│   └── RELEASE-NOTES-7.3.4.md           发布说明
└── SHA256SUMS                           发布产物的校验值
```

---

## 验证状态

### 构建 ✅

| 项目 | 结果 |
|---|---|
| 配置收敛（`olddefconfig`） | ✅ |
| 完整构建 | ✅ 退出码 0，**0 错误 / 0 警告**（gcc 15.2.0 / Ubuntu 26.04） |
| 版本串 | `7.3.4-microsoft-standard-WSL2`（无 `+`） |
| dxgkrnl | ✅ 编入（`drivers/hv/dxgkrnl/built-in.a`，vmlinux 含 `dxgprocess_create`） |
| 模块 | 746 个 `.ko`，vermagic 一致 `7.3.4-microsoft-standard-WSL2 SMP preempt mod_unload modversions` |
| 优化项自检 | ✅ `scripts/build.sh` 逐项校验 20 个配置项，全部 ok |

### 真机启动验证 ✅

WSL 2.7.10.0 / Windows 10.0.26300.9818 / Ubuntu 26.04 / Intel Core Ultra 5 125H：

| 项目 | 结果 |
|---|---|
| 内核启动 | ✅ `7.3.4-microsoft-standard-WSL2`，`uname -v` = `#2 SMP PREEMPT_DYNAMIC Wed Nov 11 20:32:36 CST 2026` |
| 启动日志 | ✅ 无 panic / BUG / oops / Call Trace |
| systemd | ✅ `running`，失败单元 **0** |
| 启动耗时 | ✅ userspace 4.075–4.446 s（7.2.8 基线 4.237 s，同量级） |
| `Percpu:` | ✅ 11,616 kB（7.2.8 11,712 kB） |
| 抢占 | ✅ `Dynamic Preempt: lazy` |
| AppArmor | ✅ 179 profiles / 103 enforce，securityfs 已挂载 |
| `/dev/dxg` | ✅ 存在，`hv_vmbus: registering driver dxgkrnl` |
| GPU | ✅ `wsl-gpu test` → `D3D12 (Intel Arc Graphics) / Accelerated: yes / OpenGL 4.6` |
| KVM | ✅ `/dev/kvm`，`nested=Y` |
| zram | ✅ `/dev/zram0` **3.9 GiB zstd**，优先级 100；连续 5+ 次起停无抖动 |
| 模块 | ✅ ntfs3 / wireguard / kvm_intel 加载卸载正常；容器/网络常用模块均可用 |
| 网络 | ✅ mirrored、DNS、HTTPS 出网、`powershell.exe` 互操作正常 |
| WSLg / 音频 | ✅ `xdpyinfo` 正常；PulseAudio `RDPSink` 正常 |
| 启动周期 | ✅ 5 次 `wsl --shutdown` + 启动，均回到 7.3.4、失败单元 0、X11 单层挂载 |

### 说明：`journal ... corrupted or uncleanly shut down`

每次启动仍会看到 **2 条**（system + user 各一）journal 损坏提示。彻底定位过：
关机日志能走到 `poweroff.target` / `Shutting down.`，但 WSL 的 init-systemd 只等
10 秒（`InitTerminateInstanceInternal`），超时后直接 `reboot(RB_POWER_OFF)` 硬关机，
journald 来不及做 final close。这是 WSL 宿主的 10 秒关机窗口行为，**不是内核问题**；
7.2.8 同样存在。之前那 96 条来自 48 次反复重启，本版已随 zram 生命周期修复降到
每次启动 2 条。杀毒/DB/容器多的机器关机偶尔会超过 10 秒，表现为 `wsl --shutdown`
约 11 秒返回。

---

## 已知限制

- **`/mnt/c`、`/mnt/d` 的 9P 性能不是内核能修的**：单文件创建 ext4 0.03 ms vs
  9P 2.6 ms（约 100×）；宿主用 `trans=fd` 且未暴露 virtio-9p 设备，`msize` 调大
  实测无效。要快就把项目放在 `/home/<user>`。
- **`dxgkio_query_adapter_info: Ioctl failed: -22`**：Windows 侧显卡驱动与 WSL
  的适配器查询不匹配；7.2.8/7.1.4 上相同。GPU 实际可用（d3d12 测试通过）。
- **`PCI: Fatal: No config space access function found` / `eVMCS` 提示**：WSL
  虚拟化环境的固有信息，非缺陷。
- **本内核只在一台机器上验证过**：Intel Core Ultra 5 125H、WSL 2.7.10.0、
  Windows 10.0.26300.9818、Ubuntu 26.04。NVIDIA/AMD、Hyper-V 嵌套、其它发行版
  未覆盖。
- **ARM64 未覆盖**：WSL delta 的 arm64 synthetic clocks 只移植了
  `hyperv_timer.c`/Kconfig 半边，`arch/arm64/*` 未包含；x86_64 构建/启动已验证。
- **模块盘是 flat 布局**：与 Microsoft 新脚本的 nested 布局不同；改了必须重启
  用 `modprobe` 验证。
- **`hv_pci` 专用 swiotlb 池**：只有传 `hv_pci_swiotlb=` 引导参数时才创建；
  池没有 destroy 接口（与 Microsoft 58.1 相同），内建时不影响运行。

## 历史版本

- `v7.2.8-wsl-kernel.3`：Linux 7.2.8 + WSL 6.18.40.1（一键部署）
- `v7.2.8-wsl-kernel.2`：配置收敛 + delta 同步
- `v7.2.8-wsl-kernel.1`：首次 7.2.8 移植
- 更早的 7.1.3 / 7.1.4 产物在历史 release 中

## 许可

GPL-2.0-only，含 Linux-syscall-note 例外。详见 [LICENSE](LICENSE) 与
[COPYING](COPYING)。
