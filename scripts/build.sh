#!/usr/bin/env bash
# ============================================================================
# 构建带 Microsoft WSL2 支持的 Linux 内核（含本次性能优化配置）
#
# 用法:
#   ./scripts/build.sh [源码目录] [输出目录]
# 默认:
#   源码目录 = ./linux          (或 $LINUX_SRC)
#   输出目录 = ./build          (或 $LINUX_OUT)
#
# 关键约定:
#   1) LOCALVERSION 必须显式导出为空串, 否则内核名会变成
#      "7.2.8-microsoft-standard-WSL2+" (见 README).
#   2) 配置由仓库 config/config-7.2.8-wsl 提供, 先复制成 .config 再
#      olddefconfig 收敛, 保证构建可复现。
# ============================================================================
set -euo pipefail

SRC="${1:-${LINUX_SRC:-$(cd "$(dirname "$0")/.." && pwd)/linux}}"
OUT="${2:-${LINUX_OUT:-$(cd "$(dirname "$0")/.." && pwd)/build}}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${JOBS:-$(nproc)}"
FALLBACK_CONFIG="$REPO/config/config-7.2.8-wsl"

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
mkdir -p "$OUT"

cd "$SRC"
echo "=== 源码:   $SRC"
echo "=== 输出:   $OUT"
echo "=== 并发:   $JOBS"
echo "=== 版本:   $(make -s kernelrelease)"
echo

# 配置: 优先使用调用者已放在 OUT/.config 的配置, 否则取仓库里的权威副本。
# 注意 make O=... olddefconfig 会把结果写回 $OUT/.config。
if [ -f "$OUT/.config" ]; then
	echo "=== 配置:   $OUT/.config (沿用现有)"
elif [ -f "$SRC/.config" ]; then
	echo "=== 配置:   $SRC/.config"
	make O="$OUT" olddefconfig
else
	[ -f "$FALLBACK_CONFIG" ] || { echo "缺少配置文件: $FALLBACK_CONFIG" >&2; exit 1; }
	echo "=== 配置:   $FALLBACK_CONFIG -> $OUT/.config"
	mkdir -p "$OUT"
	cp "$FALLBACK_CONFIG" "$OUT/.config"
	make O="$OUT" olddefconfig
fi

make O="$OUT" -j"$JOBS"
make O="$OUT" -j"$JOBS" modules

actual="$(make -s O="$OUT" kernelrelease)"
echo
echo "=== 构建完成 ==="
echo "内核镜像: $OUT/arch/x86/boot/bzImage"
echo "版本:     $actual"
echo
echo "=== 内核配置校验 (本次优化项) ==="
for want in \
	"# CONFIG_MAXSMP is not set" \
	"CONFIG_NR_CPUS=512" \
	"# CONFIG_SCHEDSTATS is not set" \
	"# CONFIG_SCHED_STACK_END_CHECK is not set" \
	"# CONFIG_SLUB_DEBUG is not set" \
	"# CONFIG_PAGE_POISONING is not set" \
	"CONFIG_ZSWAP=y" \
	"CONFIG_ZRAM_BACKEND_ZSTD=y" \
	"CONFIG_CRYPTO_ZSTD=y" \
	"CONFIG_LRU_GEN=y" \
	"CONFIG_LRU_GEN_ENABLED=y" \
	; do
	if grep -qxF "$want" "$OUT/.config"; then
		printf '  ok   %s\n' "$want"
	else
		printf '  FAIL %s\n' "$want" >&2
	fi
done
