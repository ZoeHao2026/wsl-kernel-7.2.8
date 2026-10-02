#!/usr/bin/env bash
# ============================================================================
# 把 make modules_install 的输出目录打包成 WSL 可用的模块 VHDX。
#
# 用法:
#   ./scripts/gen-modules-vhdx.sh <模块根目录> <kernelrelease> <输出.vhdx> [布局]
#
#   布局: flat (默认) 或 nested, 见下方「目录布局」。
#
# 例:
#   ./scripts/gen-modules-vhdx.sh ./modules-root 7.2.8-microsoft-standard-WSL2 \
#       ./modules-7.2.8-microsoft-standard-WSL2.vhdx
#
# 目录布局
# --------
#   flat   —— 镜像根就是 <kernelrelease>/。本机 7.2.8 及更早的模块盘使用的
#             就是这个布局，已经实际验证能启动，所以是默认值。
#   nested —— <kernelrelease>/{modules,linux-headers,perf}。这是 Microsoft
#             WSL 内核仓库更新 gen_modules_vhdx.sh 之后的布局。
#
# 两种都可以，但**换了布局必须重启验证**：布局是内核在启动时去找模块的东西，
# 猜错的后果是模块全部不可用。默认保持与现网一致的 flat。
#
# 为什么不直接把 <模块根目录> 拷进去
# -----------------------------------
# modules_install 会在 <kernelrelease>/ 下留 build 和 source 两个软链接, 它们
# 指向构建机上的内核源码树。WSL 里那个路径并不存在, 直接打包会产生悬空链接,
# 因此打包前删除。
#
# 实现
# ----
# 用 mke2fs -d 从一个目录直接构建 ext4 镜像（无需挂载, 不需要 root 挂载权限）,
# 再用 qemu-img convert 转成 VHDX。与 Microsoft 自己的 gen_artifacts_vhdx.sh
# 采用相同的块大小与预留 inode 策略:
#   * -b 1024 —— 模块树里小文件很多, 小块减少内部碎片;
#   * -N 预留 inode —— 按实际文件数 + 4096 计算, 避免 inode 耗尽;
#   * 镜像大小 —— 实际占用 + 256 MiB 余量。
# ============================================================================
set -euo pipefail

usage() {
	printf '用法: %s <模块根目录> <kernelrelease> <输出.vhdx> [flat|nested]\n' "$0" >&2
	exit 1
}

[ $# -ge 3 ] && [ $# -le 4 ] || usage
modules_root="$1"
kernelrelease="$2"
out_vhdx="$3"
layout="${4:-flat}"

[ -d "$modules_root" ] || { printf '模块根目录不存在: %s\n' "$modules_root" >&2; exit 1; }
[ -d "$modules_root/lib/modules/$kernelrelease" ] || {
	printf '在 %s/lib/modules/ 下找不到 %s —— 先把 make modules_install 跑到这个目录\n' \
		"$modules_root" "$kernelrelease" >&2
	exit 1
}

case "$layout" in
flat|nested) ;;
*) printf '布局只能是 flat 或 nested, 收到: %s\n' "$layout" >&2; exit 1 ;;
esac

if [ -e "$out_vhdx" ]; then
	printf '拒绝覆盖已存在的文件: %s\n' "$out_vhdx" >&2
	exit 2
fi

for tool in mke2fs qemu-img du find; do
	command -v "$tool" >/dev/null 2>&1 || { printf '缺少工具: %s\n' "$tool" >&2; exit 1; }
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# ---------------------------------------------------------------------------
# 两种布局
#
#   flat   —— 镜像根就是 <kernelrelease>/ (modules.dep, kernel/, ...)。
#             这是本机 7.2.8 及其之前的模块盘实际使用的布局, 已验证能启动。
#             **默认值**, 与现网部署保持一致。
#
#   nested —— <kernelrelease>/{modules,linux-headers,perf}。这是 Microsoft
#             WSL 内核仓库更新后的 gen_artifacts_vhdx.sh 产出的布局, 额外
#             支持随盘携带 UAPI 头与 perf。本仓库不打包这两个附件, 因此
#             nested 下只有一个 modules 子目录。
#
# 改布局等于改内核只认的东西 —— 换了必须重启后用 lsmod / modprobe 验证。
# ---------------------------------------------------------------------------
staging="$tmp_dir/staging"
mkdir -p "$staging"

if [ "$layout" = "flat" ]; then
	printf '=== 复制模块树 (flat 布局) ===\n'
	cp -r "$modules_root/lib/modules/$kernelrelease/." "$staging/"
	dest="$staging"
else
	printf '=== 复制模块树 (nested 布局) ===\n'
	dest="$staging/$kernelrelease/modules"
	mkdir -p "$dest"
	cp -r "$modules_root/lib/modules/$kernelrelease/." "$dest/"
fi

# 指向构建机源码树的悬空软链接, WSL 里没有意义
rm -f "$dest/build" "$dest/source"

staging_bytes="$(du -bs "$staging" | awk '{print $1}')"
image_bytes=$((staging_bytes + (256 * (1 << 20))))
image_blocks=$((image_bytes / 1024))
inode_count=$(( $(find "$staging" | wc -l) + 4096 ))

printf '=== 内容占用 %s 字节, 镜像 %s 个 1KiB 块, 预留 %s 个 inode ===\n' \
	"$staging_bytes" "$image_blocks" "$inode_count"

mke2fs -q -L '' -d "$staging" -N "$inode_count" -b 1024 -t ext4 \
	"$tmp_dir/modules.img" "$image_blocks"

printf '=== 转换为 VHDX ===\n'
qemu-img convert -O vhdx "$tmp_dir/modules.img" "$out_vhdx"

printf '=== 完成: %s ===\n' "$out_vhdx"
ls -la "$out_vhdx"
