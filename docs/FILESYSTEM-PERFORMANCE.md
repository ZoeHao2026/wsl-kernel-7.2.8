# 跨文件系统性能：Microsoft 的建议在**这台机器**上值多少

本文把 Microsoft 官方文档
[跨 Windows 和 Linux 文件系统工作 → 跨文件系统的文件存储和性能](https://learn.microsoft.com/zh-cn/windows/wsl/filesystems#file-storage-and-performance-across-file-systems)
的建议换算成本机实测数字，并交代这个内核在**内核层面**能改什么、不能改什么。

结论先放：文档说「把文件放在 WSL 文件系统里」是对的，而且差距比多数人以为的大得多；
但**这个差距不是内核能修的**——它是 WSL 宿主侧实现的属性。

---

## 1. 实测：两条路径差多少

同一台机器、同一次会话、同一套脚本（[`scripts/run-fs-bench.sh`](../scripts/run-fs-bench.sh)）：

| 路径 | 顺序写 | 顺序读 | create | stat | unlink |
|---|---|---|---|---|---|
| ext4（`/`，VHD `sdd`） | **2.8 GB/s** | **6.5 GB/s** | 0.02 ms/文件 | 2.1 ms/文件 | 0.76 ms/文件 |
| 9p（`/mnt/d` → `D:\`） | 239 MB/s | 293 MB/s | **2.04 ms/文件** | 3.9 ms/文件 | **3.82 ms/文件** |

换算成日常感受更直观：

- 顺序吞吐差 **约 12×（写）/ 22×（读）**
- 单个文件创建差 **约 100×**
- `npm install` / `cargo build` / `git status` 这类**元数据密集**操作，命中的正是
  差 100× 的那一栏——这才是「在 `/mnt/c` 里跑构建特别慢」的真正原因，
  不是带宽不够。

> 注：ext4 一栏用 `O_DIRECT` 绕开页缓存；9P 不支持 `O_DIRECT` 所以没加该选项。
> 两者的绝对值不能直接互相换算，但**数量级差距**在任何测法下都成立，
> 且与「元数据往返次数」成正比。

---

## 2. 为什么内核改不了这一栏

搞清楚 9P 是怎么接进来的，就知道优化空间在哪：

```text
A:\PCI 上实际存在的 virtio 设备
  1af4:1043  virtio-console
  1af4:105a  virtio-fs      ← 只给 WSLg 用（dmesg: "virtiofs virtio1: discovered new tag: wslg"）
  1af4:1001  virtio-blk     ← ext4 根盘走这里
```

`/mnt/c`、`/mnt/d` 的挂载参数是：

```text
aname=drvfs;path=D:\;uid=1000;gid=1000;symlinkroot=/mnt/,
cache=0x5,access=client,msize=65536,trans=fd,rfd=6,wfd=6
```

四个关键点：

1. **`trans=fd`，不是 `trans=virtio`。** 走的是宿主与 guest 之间传过来的文件描述符，
   每个 9P 请求都要在 Windows 侧的用户态服务上往返一次。这就是那 2~4 ms 的来源。
2. **宿主没有向 guest 暴露 virtio-9p 设备。** 上面那段 PCI 列表里没有它，
   所以 `trans=virtio` 在本机上不可用——这一点用 `lspci -nn` 就能确认，
   不是猜测。内核虽已编入 `CONFIG_NET_9P_VIRTIO=y`，但没有设备可挂。
3. **`virtiofs` 只服务 WSLg。** 本机确实编了 `CONFIG_VIRTIO_FS=y` 和 `CONFIG_FUSE_DAX=y`，
   `dmesg` 也能看到 virtiofs 发现了 `wslg` 标签和约 8 GiB 的 DAX 窗口——
   但那是 WSLg 的系统盘，**不是** `C:`、`D:`。微软并没有把 Windows 盘接到 virtiofs 上。
4. **`msize=65536` 不是瓶颈。** 实测把它放大到 262144：吞吐 270 MB/s → 261 MB/s，
   没有改善（略微下降，属于噪声范围）。瓶颈是**每请求的往返开销**，不是单请求能搬多少字节。

因此：**任何 guest 侧的内核配置改动都不会让 `/mnt/c` 变快。** 
本节列出的数字是 WSL 宿主行为的固有属性，本仓库不对它做承诺。

---

## 3. 那实际该怎么做

按「能拿回多少」排序：

| 做法 | 收益 | 代价 |
|---|---|---|
| 把项目放在 `/home/<user>/...`，而不是 `/mnt/c/...` | 元数据密集操作约 **100×**，吞吐约 **12~22×** | 文件不在 Windows 资源管理器里直接躺着；需要 `explorer.exe .` 或 `\\wsl$` 访问 |
| 用 `\\wsl.localhost\<发行版>\home\<user>` 从 Windows 访问 WSL 里的文件 | 同上 | 走的是 9P 的另一个方向，Windows 程序访问时同样不快，但**构建仍在 ext4 上**，所以快的是构建 |
| 临时/中间产物放 `/tmp`（tmpfs，本机 7.8 GiB） | 免掉磁盘 I/O | 占内存；重启即失 |
| 必须跨系统时，只搬**产物**，不搬源码树 | 把 100× 的元数据开销压到几次大文件传输 | 需要一点脚本 |

一句话：**判断标准是「谁在遍历这个目录」**。Linux 侧的工具在遍历（编译器、`git`、
`npm`、`rg`、`find`），文件就该在 ext4 上；只有让 Windows 程序直接编辑的文档，
才值得放在 `/mnt/c`。

---

## 4. 本内核这次改了什么（以及为什么这些改不了 9P）

既然 9P 那条路动不了，这次的优化集中在**内核确实能控制**的地方。逐项列出依据：

### 4.1 去掉从 Ubuntu 服务器配置继承来的开销

本仓库之前的配置直接沿用了 Microsoft 6.18.35.2 的取舍。Microsoft 自己在
后来发布的 `linux-msft-wsl-6.18.40.1` 里改掉了下面几项，本次对齐：

| 配置项 | 改前 | 改后 | 依据 |
|---|---|---|---|
| `CONFIG_MAXSMP` / `CONFIG_NR_CPUS` | 开 / `8192` | 关 / `512` | 见 §4.2；Microsoft 40.1 用 `512`（range 2–512，default 64） |
| `CONFIG_SCHEDSTATS` | `=y` | 关 | Microsoft 40.1 关闭；其唯一强制来源是本机的 `CONFIG_LATENCYTOP=y`，一并关闭 |
| `CONFIG_LATENCYTOP` | `=y` | 关 | 会 `select KALLSYMS_ALL` + `select SCHEDSTATS`，本机并不用它做延迟分析 |
| `CONFIG_SCHED_STACK_END_CHECK` | `=y` | 关 | Microsoft 40.1 关闭；去掉每次调度/中断的栈边界校验 |
| `CONFIG_SLUB_DEBUG` | `=y` | 关 | Microsoft 40.1 关闭；去掉 slab 调试元数据与 `slab_debug` sysfs |
| `CONFIG_PAGE_POISONING` | `=y` | 关 | 去掉释放/分配路径的整页毒化填充 |
| `CONFIG_STACKDEPOT` | `=y` | 关（连带） | 关掉 `LATENCYTOP` 后的连带走项，本机无非 KASAN 用户 |

**明确没有动的**：`CONFIG_INIT_ON_ALLOC_DEFAULT_ON`（Microsoft 自己也开着）、
`FORTIFY_SOURCE`、`HARDENED_USERCOPY`、`SLAB_FREELIST_RANDOM/HARDENED`、
`SLAB_BUCKETS`、`DEBUG_INFO_BTF`（eBPF 工具链前提）、`HZ=250`、
`DEFAULT_SECURITY_APPARMOR` 与 LSM 顺序（Ubuntu 26.04 依赖它加载 178 个 profile）。
本次不以牺牲这些默认来换分数。

### 4.2 关于 `NR_CPUS=8192 → 512`

要说清楚实际拿到了什么，避免夸大：

- `kernelCommandLine` 里本来就有 `nr_cpus=18`，所以**并没有**按 8192 去分配 percpu 区。
  实测 `percpu: Embedded 62 pages/cpu … u262144` 在改前改后**完全一样**。
- 真正的收益是两处**与 CPU 数无关**的静态开销：
  - `CPUMASK_OFFSTACK` 随 `MAXSMP` 一起被去掉。`sizeof(cpumask_t)` 从 1 KiB 降到 64 B（16×），
    且热路径不再走「掩码指针在堆上」的间接层。
  - 各处按 `nr_cpu_ids` 而非 `possible CPUs` 布置的静态数组缩小。
- `Percpu:` 一栏从 **12.4 MiB** 降到约 **10.3 MiB**（同一启动条件下的对比；
  该值随在线 CPU 数与活跃子系统浮动，不是固定差额）。

### 4.3 新增：压缩内存换页

| 配置项 | 值 | 理由 |
|---|---|---|
| `CONFIG_ZSWAP` | `=y` | 本机 15 GiB 内存 + 4 GiB 独立 swap（`/dev/sdc`）。压缩缓存能显著减少落到 VHD 上的 swap I/O |
| `CONFIG_ZSWAP_COMPRESSOR_DEFAULT` | `"zstd"` | zstd 压缩比优于 lzo |
| `CONFIG_CRYPTO_ZSTD` | `=y`（内建） | 若为模块，zswap 初始化时可能取不到该算法而回退到 lzo，故内建 |
| `CONFIG_ZRAM` + `ZRAM_BACKEND_ZSTD` | `=m` / `=y` | 配合 [`config/zram-wsl.service`](../config/zram-wsl.service) 提供 1.5 GiB 的 zstd 压缩交换，优先级 100 高于磁盘 swap |
| `CONFIG_LRU_GEN` + `LRU_GEN_ENABLED` | `=y` / `=y` | 多代 LRU，内存偏紧时回收效率更好 |

`zswap` **默认未开机启用**（`CONFIG_ZSWAP_DEFAULT_ON is not set`）。要用它：

```bash
# 临时启用（重启失效）
echo zstd | sudo tee /sys/module/zswap/parameters/compressor
echo 1    | sudo tee /sys/module/zswap/parameters/enabled
# 持久启用：在 %USERPROFILE%\.wslconfig 的 [wsl2] 段追加
#   kernelCommandLine=preempt=lazy zswap.enabled=1 zswap.compressor=zstd
```

### 4.4 抢占模型：一次失败的尝试，和最终的取值

原始计划是把动态抢占从 `full` 收到 `voluntary`。**这个做法在 7.2.8 的 x86 上做不到**，
值得记录下来免得后来者重走：

- 内核启动日志给出明确拒绝：
  `Dynamic Preempt: unsupported mode: voluntary`
- 原因是 `kernel/sched/core.c` 的 `sched_dynamic_mode()`：

  ```c
  # if !(defined(CONFIG_PREEMPT_RT) || defined(CONFIG_ARCH_HAS_PREEMPT_LAZY))
      if (!strcmp(str, "none"))       return preempt_dynamic_none;
      if (!strcmp(str, "voluntary"))  return preempt_dynamic_voluntary;
  # endif
      if (!strcmp(str, "full"))       return preempt_dynamic_full;
  # ifdef CONFIG_ARCH_HAS_PREEMPT_LAZY
      if (!strcmp(str, "lazy"))       return preempt_dynamic_lazy;
  # endif
  ```

  x86 `select ARCH_HAS_PREEMPT_LAZY`，于是 `none` 与 `voluntary` **在编译期就被排除**，
  内核只认 `full` 和 `lazy`；`CONFIG_PREEMPT_VOLUNTARY` 也因 `depends on
  !ARCH_HAS_PREEMPT_LAZY` 而根本无法选中。
- 最终取值：`preempt=lazy`（`.wslconfig` 的 `kernelCommandLine`）。
  lazy 是「full 的调度器驱动版本」，在保持可抢占的同时减少锁持有者被抢占，
  比默认的 eager full 更省。启动日志应出现 `Dynamic Preempt: lazy`，
  运行时 `/sys/kernel/debug/sched/preempt` 显示 `full (lazy)`。
  不想要的话，删掉 `kernelCommandLine` 里那一段即可回到默认。

### 4.5 顺带修掉的一个真实缺陷

`dxgkio_open_syncobj_from_syncfile()` 只在错误路径释放引用，成功路径上创建的
`dxgsyncobject` 永久泄漏（每次成功 ioctl 泄漏一个对象及其共享 syncpoint 引用）。
Microsoft 在 6.18.40.1 修了这个；本次把补丁基线同步过去，见
[`patches/series/0004-wsl2-6.18.40.1-syncfile-leak-fix.patch`](../patches/series/0004-wsl2-6.18.40.1-syncfile-leak-fix.patch)。

---

## 5. 改动前后实测对比

同一脚本、同一机器（详见 §1）：

| 指标 | 改前（kernel.1） | 改后（kernel.2） | 说明 |
|---|---|---|---|
| `NR_CPUS` | 8192 | 512 | — |
| `Percpu:` | 12576 kB | ~10300–10560 kB | 随在线 CPU 浮动 |
| ext4 顺序写 | 2.8 GB/s | 2.2 GB/s | 单次 `dd`，波动范围大，不宜当回归 |
| ext4 顺序读 | 6.5 GB/s | 9.9 GB/s | 同上 |
| ext4 create（300 文件） | 6 ms | 9 ms | 都在个位数 ms，噪声主导 |
| ext4 unlink（300 文件） | 229 ms | 224 ms | 基本不变 |
| 9p 写 / 读 | 239 / 293 MB/s | 256 / 288 MB/s | **基本不变**，符合 §2 结论 |
| 9p create / unlink | 2.04 / 3.82 ms | 2.23 / 4.43 ms | **没有改善**，如实记录 |

**怎么读这张表**：`/` 上的顺序吞吐是单次 `dd` 采样，本机在 GB/s 量级上
run-to-run 波动可达 ±50%（同一内核多次运行也能看到 2.0↔2.8 GB/s），
所以那些变化**不构成证据**。真正稳定、且与本次改动**因果对应**的是配置项本身
（`NR_CPUS`、`Percpu:`、`zswap`/`zram` 可用性、抢占模式）——这些是确定性的。
9p 一栏没有改善，正是 §2 预言的结果：那部分不归内核管。

需要复现或自己重测：

```bash
./scripts/run-fs-bench.sh /tmp/bench-$(uname -r).txt
```

---

## 6. 部署层修复：三件与内核无关但确实影响可用性的事

以下三项**都不改内核**（内核侧在本版已无待办），属于 WSL 环境配置。记录在此是因为
它们各自都曾表现为"内核/驱动有问题"，而实际原因不同。

### 6.1 `/tmp/.X11-unix` 的启动竞态 —— 一半的冷启动会让所有 GUI 程序失败

**现象**：`DISPLAY=:0`，GUI 程序报 `couldn't connect to display ":0"`。
**实测频率**：10 次冷启动里约一半失败，不是罕见情况。

**根因**（用 `findmnt`、`/proc/self/mountinfo`、`systemctl status` 逐步确认）：

WSL 会生成一个 `wslg.service`，内容是

```
/bin/mount -o bind,ro,X-mount.mkdir -t none /mnt/wslg/.X11-unix /tmp/.X11-unix
```

它只声明了 `After=tmp.mount`。而 `/tmp` 本身是 `tmp.mount` 挂上来的 tmpfs：

```
tmp.mount: Directory /tmp to mount over is not empty, mounting anyway.
tmp.mount  Mounted  [3.323515]
```

两者存在时序竞态。当 `mount(8)` 抢在 tmpfs 就位之前跑完时，它是在 rootfs 的 `/tmp`
上建出挂载点的，随后 tmpfs 盖到 `/tmp`，把这个路径整个盖住。结果：

- `mount` 表里有 `/tmp/.X11-unix`（一条 `none[/.X11-unix] tmpfs ro` 记录）
- 文件系统里**没有**这个路径（`stat` 报 No such file or directory）
- 于是 `:0` 无法解析，GUI 全线失败
- 关机时 `umount` 该路径报 `not mounted`，失败状态被带进下一次启动 ——
  这就是本仓库 README 里长期记录的 `systemctl is-system-running` = `degraded`
  的真正来源（**不是内核问题**，此前只能存疑）

**修复**（两层，都已落地并各测 5 次冷启动）：

1. `/etc/profile.d/50-wsl-display.sh` —— 登录时若 `:0` 不通而
   `/mnt/wslg/.X11-unix/X0` 在，就把 `DISPLAY` 指向后者。
   该路径由 virtiofs 提供、不受 `/tmp` 竞态影响，因此是**确定**的。
   实测 5/5 冷启动 GUI 均可用。
2. `wsl-x11-socket.service` + `/usr/local/libexec/ensure-wsl-x11-socket.sh` ——
   启动时尽力把 `/tmp/.X11-unix` 修回来（幂等，已可用则不动；失败也不让启动变
   failed），覆盖不读取 profile 的场景（systemd 用户单元、容器、IDE 后端）。
   实测在服务跑起来的那些启动里，`env -i DISPLAY=:0` 与 `systemd-run` 两种
   非登录上下文都能连上。

> 试过但**无效**的两种做法，记下来免得后来者重走：
> 用 `tmpfiles.d` 建目录 —— Ubuntu 里 `systemd-tmpfiles-setup.service` 被 WSL
> 禁用（`ConditionResult=no`），规则不会执行；用 `systemd-tmpfiles --create`
> 手动跑才生效，但启动时不会跑。以及用 `mask` 遮蔽同路径的 tmpfs 单元 ——
> 竞态来自 WSL 自己的 `mount` 命令，遮蔽 systemd 侧单元改变不了它。

### 6.2 GPU 硬件加速：可用，但默认**不应该**开

**此前的结论需要更正**：不存在"必须更新 Windows 驱动才能有 GPU"这回事。
`/dev/dri` 确实不存在，但 Mesa 的 `d3d12` 后端走的是 WSL 的 `libdxcore.so`
用户态桥，**绕过 `/dev/dri`，也绕过 dxgkrnl 的适配器查询**。所以本机那 10 条
`dxgkio_query_adapter_info: Ioctl failed: -22` 对这条路径没有影响。

实测：

```text
默认:     llvmpipe (LLVM 21.1.8, 256 bits)   Accelerated: no    OpenGL 4.5
d3d12:    D3D12 (Intel(R) Arc(TM) Graphics)  Accelerated: yes   OpenGL 4.6
```

**但默认不启用**，因为实测普通 GUI 负载并不会更快：

| 负载 | llvmpipe（默认） | d3d12 |
|---|---|---|
| glxgears 小窗口（同步/往返密集） | 1060 FPS | 199 FPS |
| glxgears 1600×1000（填充率） | 316 FPS | 118 FPS |
| Tk 顶点密集型画布 1280×720 | 137 fps | 136 fps |

原因是每次 GL 调用都要从 guest 经共享内存通道打到 Windows 侧的 GPU，往返延迟
盖过了硬件收益；而这些负载本来就被 X11 传输和 CPU 支配，不卡在渲染上。
`d3d12` 的价值在**软件渲染跑不动**的场景：需要 OpenGL 4.6 或 Vulkan 的应用、
Blender 类 3D 负载、任何真正吃 GPU 的计算。

因此做成了具名开关而不是默认打开：

```bash
wsl-gpu status    # 查看当前渲染器 + 探测 d3d12 是否可用
wsl-gpu on        # 为之后的登录会话启用（写入 /etc/profile.d/50-wsl-gpu.sh）
wsl-gpu off       # 恢复默认软件渲染
wsl-gpu test      # 立刻用 d3d12 探测一次，不改变默认
```

### 6.3 内存只分到宿主的一半

宿主 **31.6 GiB**，而 `.wslconfig` 未设置 `memory=` 时 WSL 默认只取 **50%**，
即 15 GiB。已在 `%USERPROFILE%\.wslconfig` 的 `[wsl2]` 段加：

```ini
memory=24GB
```

实测生效：`Mem: 23Gi`（24 GB 名义值扣掉内核/固件保留后的可见值）。

顺带确认内存子系统本身不缺：逐页写满 16 GiB 无 OOM，触发压缩换页时
zram 把 **63 MiB 压到 9.2 MiB（约 2.6×）**，压缩率与容量都健康 ——
所以这一项是"把上限还给用户"，不是在救火。


## 7. 一句话结论

- **要快，就把文件放在 ext4 上**（`/home/...`），这是唯一有数量级收益的做法，
  和 Microsoft 文档的建议一致。
- `/mnt/c`、`/mnt/d` 的 9P 性能由 WSL 宿主决定，**本内核不做承诺、也改不动**；
  `msize` 调大实测无效，`trans=virtio` 因宿主未暴露 virtio-9p 设备而不可用。
- 内核侧这次清掉了从服务器配置继承来的调试/大机器开销，并补上了
  zswap、zram+zstd、MGLRU 这几个与「15 GiB 内存 + 4 GiB swap」直接相关的特性。
