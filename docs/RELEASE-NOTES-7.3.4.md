# wsl-kernel.2 — Linux 7.3.4 + Microsoft WSL2 6.18.58.1

把自定义 WSL2 内核从 **Linux 7.2.8 + WSL 6.18.40.1** 更新到
**Linux 7.3.4 + WSL 6.18.58.1**，并修复/优化部署层与本机验证过的缺陷。

---

## 一键安装

### Windows（内核 + 环境修复）

```powershell
irm https://github.com/ZoeHao2026/wsl-kernel-7.2.8/releases/latest/download/bootstrap.ps1 | iex
```

装完必须重启 WSL，并核对构建时间：

```powershell
wsl --shutdown
wsl -d Ubuntu-26.04 -- uname -r    # 期望 7.3.4-microsoft-standard-WSL2
wsl -d Ubuntu-26.04 -- uname -v    # 期望 2026-11-11 的构建时间
```

> 只替换 bzImage 而不真正重启时，WSL 会复用内存里的旧实例；`uname -r` 可能给出
> 误导性的"成功"。`uname -v` 是判断新内核是否真的启动的可靠依据。

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
```

```bash
# 状态 / 卸载（卸载只删安装器自己装的文件）
curl -fsSL .../releases/latest/download/bootstrap.sh | sudo bash -s -- --status
curl -fsSL .../releases/latest/download/bootstrap.sh | sudo bash -s -- --uninstall
```

---

## 下载

| 附件 | 大小 | 用途 |
|---|---|---|
| `bzImage-7.3.4-microsoft-standard-WSL2` | 16,749,568 B | 内核镜像 → `.wslconfig` 的 `kernel=` |
| `modules-7.3.4-microsoft-standard-WSL2.vhdx.4m00` … `.4m33` | 34 × 4 MiB（合计 142,606,336 B） | 模块盘（746 个模块）→ `kernelModules=` |
| `System.map-7.3.4-microsoft-standard-WSL2` | 9,848,020 B | 符号表，调试用 |
| `config-7.3.4-microsoft-standard-WSL2` | 200,019 B | 构建所用的完整配置 |
| `PART4M-SHA256SUMS` | — | 34 个分片的逐片校验值 |
| `SHA256SUMS` | — | 四个产物的整文件校验值 |
| `wsl-kernel-deploy.zip` / `.tar.gz` | — | 一键部署包 |
| `reassemble-modules-vhdx.ps1` / `.sh` | — | 从分片重建模块盘 |
| `bootstrap.ps1` / `bootstrap.sh` | — | 一条命令入口 |

### 模块盘为什么是分片的

本条网络到 `uploads.github.com` 的 POST 会在约 **16 MiB** 处被对端重置
（16 MiB 与 40 MiB 的测试体都在 ~16.7 MB 处断开），136 MB 的模块盘无法整文件
上传，因此按 4 MiB 分片。用 `reassemble-modules-vhdx.ps1` / `.sh` 重建会自动
逐片校验、拼接、再校验整体 SHA-256；任一步失败即中止。

重建结果应为 `142,606,336` 字节，SHA-256
`96e7165ac5fa2039e55a1b2d0f85f53573b21c54d07e9f3e49db4b54aea640b9`。

---

## 校验值 (SHA-256)

```
ae5a3126a0da90fb3408053239ae8415a4dc59eb35173858e87b01810f98b1ca  bzImage-7.3.4-microsoft-standard-WSL2
942326b9667397ff17ea4baad5049cea3bfa348fc97160ae77665dd6f84e03a7  System.map-7.3.4-microsoft-standard-WSL2
f9233c002b5d3a67984a7b55cdf75af9cb32cbf6730f5852ca250a14a6dcf71e  config-7.3.4-microsoft-standard-WSL2
96e7165ac5fa2039e55a1b2d0f85f53573b21c54d07e9f3e49db4b54aea640b9  modules-7.3.4-microsoft-standard-WSL2.vhdx（拼接后）
```

---

## 这一版包含什么

### 内核

- 上游基线 **Linux 7.3.4**（2026-11-10，kernel.org 当前 stable；7.4 尚在 rc）
  SHA-256 `b11b6df8295e8e991ff040b71aaa4994a8b55caa23b6b092907f195b5840fd1f`
- WSL 改动来源 **`linux-msft-wsl-6.18.58.1`**（2026-10-27，commit `a9891719…`）
- 配置基线：Microsoft `arch/x86/configs/config-wsl`（6.18.58.1）+ 本仓库已验证的
  调优项；`CONFIG_XEN`、`DEBUG_LIST`、`DEBUG_SG` 等继承开销去掉，
  `INIT_ON_ALLOC`、`FORTIFY_SOURCE`、`HARDENED_USERCOPY`、`DEBUG_INFO_BTF`、
  AppArmor 默认 LSM 保持不变
- 新增：`NTFS3=m`、`SQUASHFS_ZSTD=y`、`EROFS_FS_ZIP_ZSTD=y`、
  `ZRAM_DEF_COMP="zstd"`、`LRU_GEN`、`ZSWAP`(默认关)、`SWIOTLB_DEFAULT_SIZE_MB=64`
- 抢占：构建默认 `PREEMPT`，启动参数 `preempt=lazy`（实测 `Dynamic Preempt: lazy`）
- **修复 7.3 的 `mem->cc_shared` 缺口**：`swiotlb_create_pool()` 现在在
  `CC_ATTR_MEM_ENCRYPT` 平台设置 `cc_shared`，否则 VPCI DMA 会静默返回
  `DMA_MAPPING_ERROR`（paravisor/CC 客户机；普通 WSL 不受影响，但这是正确性问题）
- dxgkrnl 同步 58.1：native fence sharing（VMBus 接口 45/46）、
  `dxgsyncfile` 引用泄漏修复、ioctl/适配器修复

### 环境修复（由一键部署安装）

| 项目 | 作用 | 本机实测 |
|---|---|---|
| `/tmp/.X11-unix` 兜底 | WSL 的 wslg bind 竞态；叠加 mount 会让关机卡住 | 登录兜底 11/11；服务单元 5/5；修复后 mount 层数 = 1 |
| zram(zstd) 压缩交换 | 按内存 1/6 建（24 GiB 机器约 3.9 GiB 名义），优先级 100 | 连续 5+ 次起停无反复 reset |
| zram 生命周期修复 | 旧单元挂 `swap.target`，WSL 每个会话结束都会 swapoff/reset | 旧版 dmesg 48 次 Removed/Added → 现在每次启动 1 次 |
| zram 多发行版安全 | 已有任一 zram swap 时不 reset 共享 `/dev/zram0` | 幂等脚本重复执行 exit 0 |
| AppArmor/securityfs | 把 `wsl-securityfs.service` + drop-in 纳入安装，避免冷启动跳过 profile | 179 profiles / 103 enforce |
| `wsl-gpu` 开关 | Intel Arc 硬件加速（Mesa d3d12 → libdxcore） | `wsl-gpu test`: OpenGL 4.6 / Accelerated: yes |
| journal volatile | WSL 会话重启下持久 journal 必被判 unclean；改用 `/run` 后不再刷假损坏 | 启动日志 0 条 `corrupted`；`journalctl -b` 正常，跨 VM 重启不保留 |
| systemd 关机窗口 | 默认 90s 远超 WSL 的 10s；硬关机可能留下 E_UNEXPECTED 状态 | `DefaultTimeoutStopSec=5s`；实测关机 5–7 秒，10 次命令 + 2 分钟空闲稳定 |
| `memory=24GB` | 宿主 31.6 GiB，未设置时 WSL 只取 50% | 实测 Mem: 23 GiB |

### 良性日志静默（wsl-kernel.2）

`patches/7.3.4/0003-quiet-wsl-benign-logs.patch` 把三条已验证为良性的内核消息
降级，不再污染 `dmesg -l err,warn`：

- `PCI: Fatal: No config space access function found` / `System does not support PCI`
  → `KERN_INFO`
- `vmentry_ctrl / vmexit_ctrl unsupported with eVMCS` → `pr_info_once`
- `dxgkio_query_adapter_info` / `dxgkio_is_feature_enabled` 的 `-EINVAL/-ENOENT`
  → `dev_dbg`（其他错误仍按 error 记录）

外加上面环境层的 `journal Storage=volatile` 和
`kernelCommandLine=preempt=lazy intel_pstate=disable`（后者本机启用，WSL 的 CPU
调频由宿主控制）。修复后本机 `dmesg -l err,warn` 只剩 WSL 宿主侧的
`CheckConnection` 两行。

### 配置优化（对比 7.2.8）

`bzImage` **18,166,272 → 16,749,568 B**；`Percpu:` **11,712 → 11,616 kB**；
模块 **963 → 746**（关掉大量 WSL 用不到的 DRM/网卡/声卡驱动，同时新增 ntfs3 /
squashfs zstd / erofs zstd）；启动 userspace **4.237 → 4.075–4.446 s**（同量级）。

---

## 验证状态

| 项目 | 结果 |
|---|---|
| 构建 | 退出码 0，**0 错误 / 0 警告**（gcc 15.2.0 / Ubuntu 26.04） |
| 版本串 | `7.3.4-microsoft-standard-WSL2`（无 `+`），`uname -v` `#3 SMP PREEMPT_DYNAMIC Wed Nov 11 21:12:54 CST 2026` |
| 模块 | 746 个 `.ko`；vermagic 全部 `7.3.4-microsoft-standard-WSL2 SMP preempt mod_unload modversions` |
| dxgkrnl | `hv_vmbus: registering driver dxgkrnl`，`/dev/dxg` 就绪，`dxgprocess_create` 在 vmlinux 中 |
| 启动日志 | 无 panic / BUG / oops / Call Trace |
| systemd | `running`，失败单元 **0** |
| 启动耗时 | userspace 4.075–4.446 s（5+ 次冷启动） |
| AppArmor | 179 profiles 加载 / 103 enforce，securityfs 已挂载 |
| KVM | `/dev/kvm`，`nested=Y` |
| zram | `zram0 zstd 3.9G [SWAP]`，优先级 100 |
| GPU | `wsl-gpu test` → D3D12 (Intel Arc Graphics)，Accelerated: yes，OpenGL 4.6 |
| 网络 / 互操作 | mirrored、DNS、HTTPS 200、`powershell.exe` 正常 |
| WSLg / 音频 | `xdpyinfo` 正常；PulseAudio `RDPSink` 正常 |
| 模块加载 | ntfs3 / wireguard / kvm_intel 加载与卸载正常 |
| 启动周期 | 5+ 次 `wsl --shutdown` + 启动，均回到 7.3.4、失败单元 0、X11 单层挂载 |
| 关机 | `DefaultTimeoutStopSec=5s`，5–7 秒完成，不再触发 `InitTerminateInstanceInternal` |
| 稳定性 | 10 次命令 + 2 分钟空闲 + 多次起停无 E_UNEXPECTED |

### 观测到的非缺陷现象

| 消息 | 说明 |
|---|---|
| `PCI: ...` | WSL2 无传统 PCI 配置空间；**已降为 info** |
| `dxgkio_query_adapter_info` / `is_feature_enabled` | 宿主对可选探测返回 `-EINVAL/-ENOENT`；**预期错误已降为 debug**，其他错误仍记录 |
| `vmentry_ctrl / vmexit_ctrl unsupported with eVMCS` | KVM 嵌套下的信息性提示；**已降为 info_once** |
| `TCP: loopback0: Driver has suspect GRO implementation` | mirrored 网络 loopback 告警；本版实测未出现 |
| `journal ... corrupted or uncleanly shut down` | journal 已切 volatile，本机启动 0 条；持久日志模式下仍会 1–2 条，原因见下 |
| `WSL ... CheckConnection: getaddrinfo/connect failed` | WSL 宿主网络探测，不是内核；本机出网正常 |
| `Exception: Operation canceled @p9io.cpp` | WSL 宿主 9P 会话切换提示，不是内核 |

### 已知限制

- **`/mnt/c`、`/mnt/d` 的 9P 性能不是内核能修的**：单文件创建 ext4 0.03 ms vs
  9P 2.6 ms（约 100×）；宿主用 `trans=fd` 且未暴露 virtio-9p 设备，`msize` 调大
  实测无改善。把项目放在 `/home/<user>`。
- **`Wsl/Service/E_UNEXPECTED`**：5 秒关机窗口修复后本机未再复现；WSL 2.7.10
  服务层在极端情况下仍可能偶发。恢复方式：
  `wsl --terminate Ubuntu-26.04` 后重新进入。
- **`WSL ... CheckConnection` / 9P `Operation canceled`**：WSL 宿主侧网络/9P
  提示，不是内核路径；不影响实际出网与文件访问。
- **`wsl --shutdown` 偶尔 11 秒 / 持久 journal 1–2 条 unclean**：WSL 的
  init-systemd 只给 10 秒关机窗口；安装器默认用 volatile journal 规避，需要
  持久日志时可自行删除 drop-in 承担该提示。
- **本内核只在一台机器上验证过**：Intel Core Ultra 5 125H、WSL 2.7.10.0、
  Windows 10.0.26300.9818、Ubuntu 26.04。NVIDIA/AMD、Hyper-V 嵌套、其它发行版
  未覆盖。
- **ARM64 未覆盖**：WSL delta 的 arm64 synthetic clocks 只移植了
  `hyperv_timer.c`/Kconfig 半边，`arch/arm64/*` 未包含。
- **模块盘 flat 布局**：与 Microsoft 新脚本的 nested 布局不同；改了必须重启
  用 `modprobe` 验证。
- **`hv_pci` 专用 swiotlb 池**：只有传 `hv_pci_swiotlb=` 引导参数时才创建；
  没有 destroy 接口（与 Microsoft 58.1 相同），内建时不影响运行。
- **仓库名** `wsl-kernel-7.2.8` 是历史命名；`releases/latest` 已指向本版，
  旧 tag/release 原样保留。

---

## 回滚

`.wslconfig` 的备份在 `.wslconfig.bak-<时间戳>` 与
`D:\WSL\kernel-artifacts\.wslconfig.pre-7.3.4-*`；7.2.8 的内核产物完整保留在
`D:\WSL\kernel-artifacts\7.2.8-rolling\`（与原来
`...\outputs\wsl-kernel-7.2.8\` 下的文件相同）。恢复 `.wslconfig` 后
`wsl --shutdown` 即可回到 7.2.8。旧 release：
[v7.2.8-wsl-kernel.3](https://github.com/ZoeHao2026/wsl-kernel-7.2.8/releases/tag/v7.2.8-wsl-kernel.3)；
7.3.4 上一版为
[v7.3.4-wsl-kernel.1](https://github.com/ZoeHao2026/wsl-kernel-7.2.8/releases/tag/v7.3.4-wsl-kernel.1)。
环境修复用 `bootstrap.sh --uninstall` 干净卸载。

---

## 许可

GPL-2.0-only，含 Linux-syscall-note 例外。详见仓库 `LICENSE` 与 `COPYING`。
