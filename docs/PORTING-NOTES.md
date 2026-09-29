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

## 6. 未验证事项

以下**未**在本次工作中验证，使用者需自行确认：

1. **真机启动** — 未在真实 WSL 上加载该内核测试。构建成功不等于能启动。
2. **GPU 直通** — WSLg 硬件加速能否工作取决于 Windows 侧显卡驱动是否支持 D3D12
   与 GPU-PV，**与内核无关**。若 `dmesg` 出现
   `dxgkio_query_adapter_info: Ioctl failed: -22`，说明是 Windows 驱动过旧，
   而不是内核问题。
3. **模块 VHDX 生成** — 需 `Microsoft/scripts/gen_modules_vhdx.sh`，
   未包含在本仓库中。
4. **嵌套虚拟化 / KVM** — 未验证 Hyper-V 嵌套下的 KVM 行为。

---

## 7. 参考

- [Linux 7.2.8 发布](https://cdn.kernel.org/pub/linux/kernel/v7.x/ChangeLog-7.2.8)
- [Microsoft WSL2-Linux-Kernel](https://github.com/microsoft/WSL2-Linux-Kernel)
- [Intel: Intel® Arc™ Graphics Are Not Detected under WSL2](https://www.intel.com/content/www/us/en/support/articles/000094038/graphics.html)
- [microsoft/WSL#13295 — GPU Passthrough fails for Intel Arc on Meteor Lake](https://github.com/microsoft/WSL/issues/13295)
- 内核 `scripts/setlocalversion`（版本串构造逻辑）
