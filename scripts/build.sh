#!/usr/bin/env bash
# ============================================================================
# 构建带 Microsoft WSL2 支持的 Linux 内核（含本次性能优化配置）
#
# 用法:
#   ./scripts/build.sh [源码目录] [产物目录]
# 默认:
#   源码目录 = ./linux          (或 $LINUX_SRC)
#   产物目录 = ./build          (或 $LINUX_OUT)
# 环境变量:
#   JOBS=18                    并发数
#   CONFIG_FILE=...            指定要使用的配置（默认仓库里的 config/config-7.3.4-wsl）
#
# 关键约定:
#   1) LOCALVERSION 必须显式导出为空串, 否则内核名会变成
#      "7.3.4-microsoft-standard-WSL2+" (见 README)。
#   2) 采用**树内构建**：把配置放到源码树的 .config 再 make。7.2.8 时期实测
#      `make O=` 外部输出目录会因源码树不干净报
#      "The source tree is not clean, please run 'make mrproper'"，不适合脚本化。
#   3) 构建完成后把 bzImage / System.map / config 复制到产物目录。
# ============================================================================
set -euo pipefail

SRC="${1:-${LINUX_SRC:-$(cd "$(dirname "$0")/.." && pwd)/linux}}"
OUT="${2:-${LINUX_OUT:-$(cd "$(dirname "$0")/.." && pwd)/build}}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${JOBS:-$(nproc)}"
FALLBACK_CONFIG="${CONFIG_FILE:-$REPO/config/config-7.3.4-wsl}"

# ---------------------------------------------------------------------------
# 关键: LOCALVERSION 必须显式导出。
#
# scripts/setlocalversion 在「LOCALVERSION 未设置」且「有 tag 命中 HEAD」时,
# 会从 --short 分支输出一个 '+' (见 setlocalversion:115-121 与 201)。
# CONFIG_LOCALVERSION 无法抑制它 —— 只有设置 LOCALVERSION 环境变量才跳过该
# 分支。传空串即可: 名称由 CONFIG_LOCALVERSION 提供, 且不会追加任何后缀。
# ---------------------------------------------------------------------------
export LOCALVERSION=""

[ -d "$SRC" ] || { echo "源码目录不存在: $SRC" >&2; exit 1; }
cd "$SRC"

echo "=== 源码:   $SRC"
echo "=== 产物:   $OUT"
echo "=== 并发:   $JOBS"
echo "=== 版本:   $(make -s kernelrelease)"
echo

if [ -f .config ]; then
	echo "=== 配置:   沿用 $SRC/.config"
elif [ -f "$FALLBACK_CONFIG" ]; then
	echo "=== 配置:   $FALLBACK_CONFIG -> $SRC/.config"
	cp "$FALLBACK_CONFIG" .config
else
	echo "缺少配置文件: $FALLBACK_CONFIG" >&2
	exit 1
fi

# 收敛配置（新内核里失效的符号、被 select 的依赖都在这一步定下来）
make olddefconfig

# 树内构建；LOCALVERSION 已 export，脚本内不会再产生 '+'
make -j"$JOBS"
make -j"$JOBS" modules

actual="$(make -s kernelrelease)"
mkdir -p "$OUT"
cp -f arch/x86/boot/bzImage "$OUT/bzImage-$actual"
cp -f System.map            "$OUT/System.map-$actual"
cp -f .config               "$OUT/config-$actual"

echo
echo "=== 构建完成 ==="
echo "内核镜像: $OUT/bzImage-$actual"
echo "符号表:   $OUT/System.map-$actual"
echo "配置:     $OUT/config-$actual"
echo "版本:     $actual"
echo

echo "=== 内核配置校验 (本次优化项) ==="
fail=0
check() {
	if grep -qxF "$1" .config; then
		printf '  ok   %s\n' "$1"
	else
		printf '  FAIL %s\n' "$1" >&2
		fail=$((fail + 1))
	fi
}
check "# CONFIG_MAXSMP is not set"
check "CONFIG_NR_CPUS=512"
check "# CONFIG_SCHEDSTATS is not set"
check "# CONFIG_SCHED_STACK_END_CHECK is not set"
check "# CONFIG_SLUB_DEBUG is not set"
check "# CONFIG_PAGE_POISONING is not set"
check "# CONFIG_DEBUG_LIST is not set"
check "# CONFIG_DEBUG_SG is not set"
check "CONFIG_ZSWAP=y"
check 'CONFIG_ZSWAP_COMPRESSOR_DEFAULT="zstd"'
check "CONFIG_ZRAM_BACKEND_ZSTD=y"
check 'CONFIG_ZRAM_DEF_COMP="zstd"'
check "CONFIG_CRYPTO_ZSTD=y"
check "CONFIG_LRU_GEN=y"
check "CONFIG_LRU_GEN_ENABLED=y"
check "CONFIG_NTFS3_FS=m"
check "CONFIG_SQUASHFS_ZSTD=y"
check "CONFIG_EROFS_FS_ZIP_ZSTD=y"
check "CONFIG_DEFAULT_SECURITY_APPARMOR=y"
check "CONFIG_SWIOTLB_DEFAULT_SIZE_MB=64"

if [ "$fail" -ne 0 ]; then
	echo "=== $fail 项配置校验失败 ===" >&2
	exit 1
fi
echo "=== 配置校验全部通过 ==="
