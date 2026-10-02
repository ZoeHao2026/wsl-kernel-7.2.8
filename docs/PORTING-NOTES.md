# 移植记录：WSL2 6.18 → Linux 7.2.8

本文记录把 Microsoft WSL2 内核改动从 `linux-msft-wsl-6.18.y`（tag
`linux-msft-wsl-6.18.35.2`）前向移植到 `v7.2.8` 的完整过程、遇到的全部冲突、
以及每个冲突的处理依据。

---

## 1. 移植基线

| 项目 | 值 |
|---|---|
| 上游目标 | `linux-7.2.8.tar.xz` |
| 上游 SHA-256 | `12e8d5a973d1ad7c5a5c69882e4022b131ed715db7003fdcd760ddf8c3e51941` |
| 上游发布日期 | 2026-09-25 |
| WSL 改动来源 | `WSL2-Linux-Kernel`，分支 `linux-msft-wsl-6.18.y` |
| WSL 改动 tag | `linux-msft-wsl-6.18.35.2` |
| 移植补丁规模 | 25 文件 (16 新增 + 9 修改) / 约 18,000 行 |
| 工具链 | gcc 15.2.0 (Ubuntu 26.04) |

### 为什么不用增量补丁链

kernel.org 只保留最近若干个 7.1.x 增量补丁，`patch-7.1.4-7.1.5.xz` 等早期增量
已返回 404。跨系列（7.1 → 7.2）本来也没有增量补丁可用，因此采用
「完整 tarball + 完整移植补丁」的方式。

---

## 2. 冲突与处理

把 WSL 补丁直接应用到 7.2.8，`patch --forward --batch` 的报告为：

```
arch/x86/kernel/cpu/mshyperv.c   Hunk #1 FAILED at 440.     → 手工补正
drivers/hv/Makefile              Hunk #1 FAILED at 3.       → 手工补正
fs/fuse/file.c                   Reversed / already applied → 丢弃
其余 23 个文件                    全部应用成功
```

### 2.1 `drivers/hv/Makefile` — 手工补正（**关键**）

**现象**：hunk 失败，`.rej` 文件生成。

**原因**：补丁的上下文是

```
 obj-$(CONFIG_MSHV_ROOT)		+= mshv_root.o
+obj-$(CONFIG_DXGKRNL)		+= dxgkrnl/
 
 CFLAGS_hv_trace.o = -I$(src)
```

即假定 `MSHV_ROOT` 行之后紧跟一个空行。但 7.2.8 在同一位置多了一行
`obj-$(CONFIG_MSHV_VTL) += mshv_vtl.o`，上下文不再匹配。

**处理**：在 `MSHV_ROOT` 行之后插入 `obj-$(CONFIG_DXGKRNL) += dxgkrnl/`。

**后果严重性**：⚠️ **极高**。缺这一行，`drivers/hv/dxgkrnl/` 下的 15 个文件
**完全不会进入编译**，但整个构建仍会"成功"完成，产出一个看起来正常、
实则**没有 GPU 半虚拟化驱动**的内核。

### 2.2 `arch/x86/kernel/cpu/mshyperv.c` — 手工补正

**现象**：hunk #1 失败（`@@ -440,6 +440,8 @@`），hunk #2 成功。

**原因**：失败的 hunk 只是两个局部变量声明：

```c
 static void __init ms_hyperv_init_platform(void)
 {
+	union hv_hypervisor_version_info version;
+	unsigned int build = 0;
 	int hv_max_functions_eax;
```

补丁假定变量声明行是 `int hv_max_functions_eax;`，而 7.2.8 是
`int hv_max_functions_eax, eax;`（上游后来加了 `eax`），因此上下文不匹配。

**处理**：在 `int hv_max_functions_eax, eax;` 之前插入这两行声明。

**后果严重性**：⚠️ **构建直接失败**。因为成功的 hunk #2 已经在使用
`version` 与 `build`：

```c
	if (!hv_get_hypervisor_version(&version))
		build = version.build_number;
	if (build < 22621)
		ms_hyperv.features &= ~HV_ACCESS_TSC_INVARIANT;
```

声明缺失会导致编译报未定义变量。

**该 hunk 的用途**：宿主 build < 22621（Windows 11 22H2 之前）存在 invariant TSC
缺陷——宿主休眠后 guest 可能看到"变慢"的 TSC，导致合成定时器中断异常。检测到旧
宿主时主动关闭该特性以规避。

### 2.3 `fs/fuse/file.c` — 丢弃（上游已合并）

**现象**：`Reversed (or previously applied) patch detected! Skipping patch.`

**核实**：7.2.8 的 `fuse_file_put()` 已包含完全相同的内容：

```c
		} else {
			/*
			 * DAX inodes may need to issue a number of synchronous
			 * request for clearing the mappings.
			 */
			if (ra && ra->inode && FUSE_IS_DAX(ra->inode))
				args->may_block = true;
```

**处理**：丢弃，不重复应用。这不是缺陷。

### 2.4 `kernel/dma/swiotlb.c` — 上游 API 变更（编译失败）

这个是 `patch` **应用成功**、但**编译失败**的冲突——hunk 上下文匹配，语义却已改变。

**现象**：

```
kernel/dma/swiotlb.c:1958:46: error: passing argument 3 of
    'swiotlb_init_io_tlb_pool' makes pointer from integer without a cast
kernel/dma/swiotlb.c:1958:9: error: too few arguments to function
    'swiotlb_init_io_tlb_pool'; expected 6, have 5
```

**原因**：7.2.8 给该函数增加了 `void *vaddr` 参数：

```c
/* 6.18 —— 5 个参数，内部自行推导 vaddr */
static void swiotlb_init_io_tlb_pool(struct io_tlb_pool *mem, phys_addr_t start,
		unsigned long nslabs, bool late_alloc, unsigned int nareas)
{
	void *vaddr = phys_to_virt(start);      /* ← 内部计算 */
	...

/* 7.2.8 —— 6 个参数，改由调用方传入 */
static void swiotlb_init_io_tlb_pool(struct io_tlb_pool *mem, phys_addr_t start,
		void *vaddr, unsigned long nslabs, bool late_alloc,
		unsigned int nareas)
{
	...
```

移植过来的 `swiotlb_create_pool()` 沿用了旧的 5 参调用形式，而 7.2.8 中所有上游
调用点都显式传 `phys_to_virt(...)`。

**处理**（commit `e1b4e27`）：补上第三个参数。

```c
-	swiotlb_init_io_tlb_pool(pool, base, nslabs, false, nareas);
+	swiotlb_init_io_tlb_pool(pool, base, phys_to_virt(base), nslabs,
+				false, nareas);
```

池位于线性映射区，因此 `phys_to_virt(base)` 求得的地址与 6.18 版本被调方内部
计算的完全相同，行为不变。

**教训**：跨系列移植时，`patch` 应用成功**不代表语义仍然正确**。函数签名变更
只有在编译阶段才会暴露，因此移植后**必须完整构建**，不能以补丁干净应用为完成标准。

---

## 2.5 冲突处理汇总

| 文件 | `patch` 结果 | 是否需要处理 | 处理方式 |
|---|---|---|---|
| `drivers/hv/Makefile` | Hunk FAILED | ✅ 必须 | 补上 dxgkrnl 接线 |
| `arch/x86/kernel/cpu/mshyperv.c` | Hunk FAILED | ✅ 必须 | 补上变量声明 |
| `fs/fuse/file.c` | 已应用而跳过 | ❌ 不需要 | 上游已含 |
| `kernel/dma/swiotlb.c` | 应用成功 | ✅ 必须（编译期暴露） | 补 `vaddr` 参数 |

---

## 3. 静默丢失问题（重要教训）

### 问题

`patch --forward --batch` 在**部分 hunk 失败**时：

- 返回退出码 `1`
- **但仍继续处理后续文件**
- 并且对某些情况报告 "succeeded" 而实际**未插入任何内容**（在 dry-run 模式下观察到）

如果构建脚本写成：

```bash
set -euo pipefail
patch -p1 --forward --batch < patch.diff
make -j$(nproc)
```

那么在 `set -e` 下 `patch` 返回 1 会中止脚本——**但旧版构建脚本恰恰没有中止**，
于是产出了一个缺功能的"成功"内核。

### 对策

**不能只依赖 `patch` 的退出码，必须逐符号核验补丁声称添加的内容确实存在。**

本次采用的核验方式：对补丁新增的**独有标识符**逐个 grep，而非宽泛关键词。

```bash
# 好: 用补丁独有的标识符
grep -q 'HV_GPUP_DXGK_GLOBAL_GUID' include/linux/hyperv.h
grep -q 'swiotlb_create_pool'      kernel/dma/swiotlb.c
grep -q 'virtio_max_dma_size'      fs/fuse/virtio_fs.c

# 差: 宽泛关键词会产生假阳性/假阴性
grep -q 'wsl'  fs/fuse/virtio_fs.c      # 该改动与 "wsl" 字样无关
grep -q 'hv_'  kernel/dma/swiotlb.c     # 文件里本就有其他 hv_ 符号
```

### 本次核验结果

| 核验项 | 结果 |
|---|---|
| dxgkrnl 15 个文件 | ✅ 全部存在 |
| `drivers/hv/Kconfig` 引入 dxgkrnl | ✅ |
| `drivers/hv/Makefile` 接线 | ❌ → 已补正 |
| `include/uapi/misc/d3dkmthk.h` | ✅ |
| `HV_GPUP_DXGK_*` GUID | ✅ |
| mshyperv.c 变量声明 | ❌ → 已补正 |
| `swiotlb_create_pool` | ✅ |
| pci-hyperv.c 专用池 | ✅ |
| `virtio_max_dma_size` | ✅ |
| hyperv_timer.c ARM64 分支 | ✅ |

---

## 4. 内核版本串污染问题

### 现象

在 git 工作区中构建时，内核名变成 `7.2.8-microsoft-standard-WSL2+`（多一个 `+`），
而目标名是 `7.2.8-microsoft-standard-WSL2`。

### 定位过程

1. 先怀疑 `CONFIG_LOCALVERSION_AUTO` → 已禁用，**无效**
2. 再怀疑 `.config` 比 `include/config/auto.conf` 新导致的时间戳判断 → 不符实
3. 直接调用 `scripts/setlocalversion` 返回空串，但 `make kernelrelease` 有 `+` → 说明差异来自 make 注入的环境
4. 读源码定位到 `scripts/setlocalversion`：

```sh
# 第 115-121 行
if [ -z "${count}" ] || [ "${count}" -gt 0 ]; then
	# If only the short version is requested, don't bother
	# running further git commands
	if $short; then
		echo "+"
		return
	fi
	...

# 第 201 行
elif [ "${LOCALVERSION+set}" != "set" ]; then
	# If the variable LOCALVERSION is not set, append a plus
	# sign if the repository is not in a clean annotated or
	# signed tagged state
	scm_version="$(scm_version --short)"
fi
```

**结论**：只要 `LOCALVERSION` 环境变量**未设置**，就会走 `--short` 分支；
而该分支在 tag 命中 HEAD（`count=0`）时**必然**打印 `+`。

### 尝试过的错误方案

| 方案 | 结果 | 原因 |
|---|---|---|
| 禁用 `CONFIG_LOCALVERSION_AUTO` | ❌ 仍然有 `+` | 该配置只影响是否走完整 scm 分支，不影响 `--short` 分支 |
| 打 annotated tag | ❌ 仍然有 `+` | tag 命中使 `count=0`，反而**触发** `+`；无 tag 时 `count` 为空也会触发 |
| 放 `localversion` 文件 | ❌ 名字更乱 | 该文件内容与 `CONFIG_LOCALVERSION` **拼接**而非替换 |

### 正确方案

**导出 `LOCALVERSION` 环境变量（空串即可）**：

```bash
export LOCALVERSION=""
make -j$(nproc)
```

空串会让 `${LOCALVERSION+set}` 判定为已设置，跳过 `--short` 分支；
内核名由 `CONFIG_LOCALVERSION="-microsoft-standard-WSL2"` 提供，不追加任何后缀。

> **陷阱**：`LOCALVERSION=` 作为**命令前缀**（`LOCALVERSION= make ...`）只会对该条
> 命令生效；若在同一 shell 里接着跑 `make olddefconfig`，`LOCALVERSION` 不会保留，
> 可能把瞬时值写进 `include/config/auto.conf` 造成污染。**务必用 `export`。**

---

## 5. 构建验证

### 环境

| 项目 | 值 |
|---|---|
| 编译器 | gcc 15.2.0 (Ubuntu 15.2.0-16ubuntu1) |
| CPU | 18 核 |
| 内存 | 15 GiB |
| 源码树 | 树内构建（`mrproper` 后） |

> **注意**：`O=` 外部输出目录构建会报
> `The source tree is not clean, please run 'make mrproper'`。
> 若源码树里已有 `.config` / `include/config/` 等残留，必须先在源码树内
> `make mrproper`，或直接改用树内构建。

### 结果

见构建日志 `docs/build.log`（本仓库不含，因体积较大）。

| 项目 | 结果 |
|---|---|
| `olddefconfig` 收敛 | ✅ |
| 完整构建退出码 | 见下表 |
| `bzImage` | 见下表 |
| dxgkrnl 编入 | 见下表 |

### 结果

构建于 2026-09-29 完成，**退出码 0，0 个错误、0 个警告**。

| 项目 | 结果 |
|---|---|
| `olddefconfig` 收敛 | ✅ 通过 |
| 完整构建 | ✅ 退出码 0，耗时 19 分 38 秒（首轮）|
| 编译错误 | **0** |
| 编译警告 | **0** |
| `bzImage` | ✅ 18,153,984 字节 |
| `bzImage` SHA-256 | `7272a5747c90af1f607e0c3ac7cf1e907612fdd520852bc50965279aae1a2ff0` |
| `vmlinux` | ✅ 483,759,032 字节 |
| `vmlinux` SHA-256 | `c6d6d27c96b91b152dfb2f9cdf3a228f5560c00069e03cef9ef825a914ec6f6f` |
| `System.map` | ✅ 10,298,102 字节 |
| 模块数量 | 964 个 `.ko` |
| 版本串 | `7.2.8-microsoft-standard-WSL2`（**无 `+` 后缀**）|
| 模块 vermagic 一致性 | ✅ 全部为 `7.2.8-microsoft-standard-WSL2 SMP preempt mod_unload modversions` |
| 压缩方式 | xz |

### 关键子系统编入验证

以 `vmlinux` 符号表与字符串为准（非仅凭配置项）：

| 子系统 | 证据 | 结果 |
|---|---|---|
| dxgkrnl GPU 半虚拟化 | 394 个 `dxg*` 文本符号，含 `dxgprocess_create`、`dxgvmb_send_sync_msg`、`dxgkio_create_device` | ✅ |
| dxgkrnl 编译单元 | 8 个 `.o` + `built-in.a` | ✅ |
| `swiotlb_create_pool` | vmlinux 符号 | ✅ |
| hv_pci 专用 swiotlb 池 | 引导参数 `__setup_early_hv_pci_swiotlb`、initcall `hv_pci_swiotlb_alloc_pool`、sysfs 属性 `swiotlb_base`/`swiotlb_size` | ✅ |
| virtio_fs DMA 上限 | `virtio_max_dma_size` 引用 7 处 | ✅ |
| Hyper-V 基础 | `vmbus_post_msg`、`hv_init_clocksource` | ✅ |
| AppArmor | `apparmor_enabled` | ✅ |

> 说明：`hv_pci_assign_swiotlb` 在符号表中不可见，因为它是 `static` 且被内联。
> 改用其**引导参数字符串与 initcall 符号**作为证据，确认该功能确实编入。

### 复现

```bash
export LOCALVERSION=""
make -j$(nproc)
sha256sum arch/x86/boot/bzImage
```


---

### 5.1 真机启动验证

在上述构建产物基础上，实际部署到 WSL2 并启动测试。

**测试环境**：WSL 2.7.10.0 / Windows 11 (10.0.26200) / Intel Meteor Lake 核显

配置方式：`.wslconfig` 指向新内核与模块 VHDX，`wsl --shutdown` 后重启。
**注意路径必须用正斜杠**（见第 6 节的踩坑记录）。

| 验证项 | 命令 / 依据 | 结果 |
|---|---|---|
| 内核版本 | `uname -r` | ✅ `7.2.8-microsoft-standard-WSL2` |
| 启动日志致命错误 | `dmesg \| grep -iE 'panic\|BUG:\|Oops\|Call Trace'` | ✅ 无 |
| init 系统 | `systemctl is-system-running` | ✅ `running` |
| 失败单元 | `systemctl --failed` | ✅ 0 个 |
| AppArmor | `aa-status` | ✅ 178 profile 加载 / 102 enforce |
| securityfs | `findmnt /sys/kernel/security` | ✅ 已挂载 |
| 模块数量 | `find /usr/lib/modules/$(uname -r) -name '*.ko*'` | ✅ 964 个 |
| 模块加载/卸载 | `modprobe` / `modprobe -r` | ✅ wireguard、zram、kvm_intel 双向正常 |
| dxgkrnl 注册 | `dmesg \| grep dxgkrnl` | ✅ `hv_vmbus: registering driver dxgkrnl` |
| GPU 设备节点 | `ls /dev/dxg` | ✅ 存在 |
| KVM 嵌套 | `/sys/module/kvm_intel/parameters/nested` | ✅ `Y` |
| 网络模式 | `wslinfo --networking-mode` | ✅ `mirrored` |
| 出网 | `curl -I https://www.kernel.org/` | ✅ 200 |
| 代理注入 | `env \| grep proxy` | ✅ 自动注入 |
| Windows 互操作 | `/mnt/c`、`powershell.exe` | ✅ 可用 |
| WSLg GUI | 启动 Tk 窗口程序 | ✅ 窗口创建并正常销毁 |
| 音频 | `pactl info` | ✅ `Default Sink: RDPSink` |
| 时间同步 | `timedatectl` | ✅ 与宿主一致 |
| 内存 / swap | `free -h` / `swapon --show` | ✅ 15 GiB + 4 GiB |
| 负载测试 | 4 个 CPU 密集进程并发 | ✅ 正常完成，无 OOM |

**结论**：内核可正常启动并完整工作，dxgkrnl、AppArmor、模块、网络、WSLg 全部就绪。

### 5.2 观测到的非缺陷现象

以下消息在启动日志中出现，但**均非本内核引入的缺陷**：

| 消息 | 说明 |
|---|---|
| `PCI: System does not support PCI` / `No config space access function found` | WSL2 是虚拟化环境，无传统 PCI 配置空间。7.1.4 同样存在 |
| `dxgkio_query_adapter_info: Ioctl failed: -22` ×10 | **Windows 侧显卡驱动过旧**，无法完成适配器查询。7.1.4 上完全相同的 10 次 |
| `vmentry_ctrl / vmexit_ctrl unsupported with eVMCS` | KVM 在 Hyper-V 嵌套下的信息性提示。7.1.4 上同样存在 |
| `TCP: loopback0: Driver has suspect GRO implementation` | mirrored 网络模式的 loopback 告警，非致命 |
| `journal ... corrupted or uncleanly shut down` | `wsl --shutdown` 直接终止 VM，journald 来不及收尾。**非内核问题**，且本次启动新增残留为 0 |

### 5.3 未验证事项

1. **GPU 硬件加速** — 未启用，但取决于 Windows 显卡驱动而非内核。`dxgkrnl` 侧已就绪。
2. **其他硬件** — 仅在 Intel Meteor Lake 核显上测试，未覆盖 NVIDIA / AMD。
3. **Hyper-V 嵌套与嵌套虚拟化** — 未做深入测试（`/dev/kvm` 与 `nested=Y` 已确认存在）。
4. **其他发行版** — 仅在 Ubuntu 26.04 上验证。

---

## 7. 参考

- [Linux 7.2.8 发布](https://cdn.kernel.org/pub/linux/kernel/v7.x/ChangeLog-7.2.8)
- [Microsoft WSL2-Linux-Kernel](https://github.com/microsoft/WSL2-Linux-Kernel)
- [Intel: Intel® Arc™ Graphics Are Not Detected under WSL2](https://www.intel.com/content/www/us/en/support/articles/000094038/graphics.html)
- [microsoft/WSL#13295 — GPU Passthrough fails for Intel Arc on Meteor Lake](https://github.com/microsoft/WSL/issues/13295)
- 内核 `scripts/setlocalversion`（版本串构造逻辑）

---

## 8. 部署踩坑：`.wslconfig` 的路径必须用正斜杠

这是一个**会静默失败**的陷阱，实测踩到，值得单独记录。

### 现象

按微软官方文档的写法使用双反斜杠：

```ini
[wsl2]
kernel=C:\\Users\\me\\bzImage-7.2.8-microsoft-standard-WSL2
kernelModules=C:\\Users\\me\\modules-7.2.8.vhdx
```

WSL 启动时报：

```
wsl: 无法解析 C:\Users\me\.wslconfig 第 2 行，忽略该行
wsl: 无法解析 C:\Users\me\.wslconfig 第 3 行，忽略该行
```

单反斜杠同样被拒。**只有正斜杠可用**：

```ini
kernel=C:/Users/me/bzImage-7.2.8-microsoft-standard-WSL2
kernelModules=C:/Users/me/modules-7.2.8.vhdx
```

### 为什么危险

WSL **不会**因为配置无效而报错退出，而是**静默回退到微软自带内核**：

```
$ wsl -d Ubuntu-26.04 -- uname -r
6.18.33.2-microsoft-standard-WSL2      ← 根本不是我们的内核
```

如果不核对 `uname -r`，会以为自定义内核"启动成功了"，实际上跑的是自带内核，
后续所有"验证通过"的结论都是假的。

### 对策

1. 一律使用**正斜杠**
2. 切换后**必须**用 `uname -r` 确认内核版本
3. 排查时留意 `wsl` 命令的 stderr——它在输出里混着这类中文告警，容易被忽略

> 环境记录：WSL 2.7.10.0 + `networkingMode=mirrored`。可能是该版本在 mirrored 模式下
> 的解析差异，但无论原因如何，正斜杠是所有情况下都能工作的写法。

---

# Delta 同步：6.18.35.2 → 6.18.40.1（wsl-kernel.2）

本节记录第二次更新：沿用同一个上游基线 `linux-7.2.8`（当时 kernel.org 最新的
stable 就是它，7.3 还在 `-rc5`），但把 Microsoft 侧的移植来源从
`linux-msft-wsl-6.18.35.2` 前移到 **`linux-msft-wsl-6.18.40.1`**。

## 为什么只换 Microsoft delta，不动上游版本

`https://www.kernel.org/releases.json` 当时给出的状态是：

```
latest_stable: 7.2.8        (2026-09-25)
mainline:      7.3-rc5
longterm:      6.18.54 / 6.12.111 / 6.6.157 / 6.1.188 / 5.15.221 / 5.10.270
```

也就是说**没有更新的 stable 可升**。而 Microsoft 的滚动 LTS 分支
`linux-msft-wsl-6.18.y` 已经前移到 `6.18.40.1`（40.1 那个 commit 正是该分支
HEAD），所以能升的是 delta 本身。

## 怎么确定 delta 到底改了哪些文件

`linux-msft-wsl-6.18.35.2..linux-msft-wsl-6.18.40.1` 的**全量** diff 是 2318 个文件，
但绝大部分是 `Linux 6.18.36…6.18.40` 的 stable 内容——对我们的 7.2.8 树毫无意义。

有效做法是先确认 **tag 点本身**：

```text
merge-base(6.18.35.2, 6.18.40.1) = 1bd4ed3d = 6.18.35.2 tag 指向的 commit
```

也就是说 6.18.35.2 是 6.18.40.1 的祖先，两者之间**没有分叉**，
上游 stable 的增量全部夹在 `Microsoft/` 自有改动之间。于是：

- 从 `MSFT-Merge/log` 与该区间内带 WSL 前缀的 commit 取 Microsoft 自有改动
  （`WSL: Bundle headers and perf in the modules VHDX`、`x86 config optimizations`、
  `Enable CONFIG_MEMCG_V1`、`WSL: Update custom kernel packaging documentation` …）
- 排除 `1bd4ed3d..` 区间里的纯上游 commit

结论：**on-tree 的代码改动只有 3 个驱动文件**。

| 文件 | 6.18.40.1 的改动 | 本仓库怎么处理 |
|---|---|---|
| `drivers/hv/dxgkrnl/dxgsyncfile.c` | `cleanup:` 路径修 syncobj 引用泄漏 | 采纳 → `0004` |
| `drivers/hv/dxgkrnl/dxgvmbus.h` | `u64 fence_values[1]` → `fence_values[]` | **无需处理**，`0002` 已经做了同一件事 |
| `drivers/hv/dxgkrnl/dxgvmbus.c` | `cmd_size` 去掉多余的 `- sizeof(u64)` | **无需处理**，`0002` 已经做了同一件事 |
| `include/linux/hyperv.h` | VMBus 版本/通道标志宏重构 + `VERSION_WIN10_V6_0` + paravisor 标志 | **无需处理**：这些是上游改动，Linux 7.2.8 里**已经有**，且比 6.18.40.1 更新 |

最后一条值得单独强调：我们**不**把 `include/linux/hyperv.h` 退回 6.18.40.1 的版本。
把 6.18.40.1 的该文件与 7.2.8 的原生版本做过逐项对比——7.2.8 是所有
`VERSION_*` / `VMBUS_CHANNEL_*` 宏的超集，回退等于降级。

## 为什么 `0004` 只有一个 hunk

第一次尝试把 35.2→40.1 的整块 delta 直接打上去，结果是 **1 个 hunk 失败、
2 个 hunk 被判定 already applied**。原因是那份 delta 是相对 **35.2 原始文件**生成的，
而本地树的起点是「35.2 + 已经应用过的 0002」。

正确做法是把补丁相对**它真正要落的那个状态**生成，也就是
「0001 + 0002 + 0003 之后的树」：

```bash
# 建参考树
tar xf linux-7.2.8.tar.xz && cd linux-7.2.8
patch -p1 < .../0001-port-Microsoft-WSL2-6.18-support-onto-Linux-7.2.8.patch
patch -p1 < .../0002-dxgkrnl-use-a-flexible-array-member-for-fence_values.patch
patch -p1 < .../0003-swiotlb-pass-vaddr-to-swiotlb_init_io_tlb_pool.patch
# 与最终树 diff，只有 dxgsyncfile.c 真正不同
diff -u 参考树/drivers/hv/dxgkrnl/dxgsyncfile.c 最终树/... 
```

这样 `0004` 就退化成一个 6 行 hunk，语义干净，也不会和 `0002` 抢同一段代码。

## 端口一致性验证

打完 4 个补丁后，与 Microsoft 40.1 的同名文件逐字节比对：

```text
drivers/hv/dxgkrnl/dxgsyncfile.c   IDENTICAL to 6.18.40.1
drivers/hv/dxgkrnl/dxgvmbus.h      IDENTICAL to 6.18.40.1
drivers/hv/dxgkrnl/dxgvmbus.c      DIFFERS by one spelling:
    - current_pos = (u8 *) command->fence_values;    (Microsoft)
    + current_pos = (u8 *)&command[1];               (本仓库, 来自 0002)
```

这两行指向同一地址（同一个柔性数组头之后）。保留本仓库的写法：
`&command[1]` 不依赖柔性成员的 offset，意图更明确，也是 `0002` 原本就写明要这么做的。

## 模块 VHDX 的布局：本次最值得记下来的坑

Microsoft 在 40.1 里把 `Microsoft/scripts/gen_modules_vhdx.sh` 换成了
`gen_artifacts_vhdx.sh`，模块盘布局从

```text
<kernelrelease>/{modules.dep, kernel/, ...}          # 平铺
```

改成

```text
<kernelrelease>/{modules, linux-headers, perf}       # 嵌套
```

新布局还顺带把 UAPI 头和 perf 一起塞进模块盘，并加了「拒绝覆盖已存在文件」的保护。

**照抄新布局会导致内核起不来模块。** 判断依据不是文档而是实测：
把两个 VHDX 都转成 raw 后用 `debugfs` 看根目录——

```bash
qemu-img convert -O raw modules-...vhdx /tmp/x.img
debugfs -R "ls -l /" /tmp/x.img
```

- 本机**正在运行**的 kernel.1 模块盘：根目录直接就是 `kernel/`、`modules.dep` …（平铺）
- 按新脚本生成的盘：根目录下只有 `7.2.8-microsoft-standard-WSL2/`，模块在它里面

因此 [`scripts/gen-modules-vhdx.sh`](../scripts/gen-modules-vhdx.sh) 默认产出
**平铺**布局（`flat`），并保留 `nested` 作为可选参数。同时必须补掉新脚本做的两件事：

1. 删掉 `build` / `source` 两个指向构建机源码树的悬空软链接；
2. `mke2fs -b 1024` + 按实际文件数预留 inode（小文件多，默认 4 KiB 块和默认
   inode 数都会出问题）。

## 配置差异：这次真正的优化落点

Microsoft 在 40.1 里重写了 `arch/x86/configs/config-wsl`（`Microsoft/config-wsl`
是指向它的符号链接；该文件从 8757 行缩到 7402 行）。把它与仓库沿用的
6.18.35.2 配置逐项对比后，本次采纳的收敛项与理由见
[`docs/FILESYSTEM-PERFORMANCE.md`](FILESYSTEM-PERFORMANCE.md) §4。

其中一条属于「不看新配置就绝对想不到」的连带关系，单独记在这里：

```text
CONFIG_LATENCYTOP=y  --select-->  CONFIG_KALLSYMS_ALL=y
                     --select-->  CONFIG_SCHEDSTATS=y
```

所以单发 `--disable SCHEDSTATS` 是**无效的**：`make olddefconfig` 会立刻把它重新
select 回来（本次实测确认过，改完仍是 `CONFIG_SCHEDSTATS=y`）。
必须先把 `LATENCYTOP` 关掉，`SCHEDSTATS` 才真的能关。

## 部署窗口

更换内核镜像需要 `wsl --shutdown`。为把风险压到最小，本次分两步：

1. **只换 `bzImage`，保留 kernel.1 的模块盘**，重启验证能起来 →
   这一步就把「镜像是否可用」和「模块盘是否可用」两个变量分开了；
2. 起来之后再换模块盘，重启确认 963 个模块可用。

另外记录一个操作上的教训：`artifacts-kernel.1/` 里的旧产物是**先备份再替换**的，
中途有一次 `Remove-Item` 删掉了在用的 `bzImage` 而新文件还没就位——
因为提前做了备份，才没有造成不可启动的状态。**换内核镜像时，先确认备份存在、
再删旧文件**，顺序不要反。
