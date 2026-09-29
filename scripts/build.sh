#!/usr/bin/env bash
# ============================================================================
# 构建带 Microsoft WSL2 支持的 Linux 内核
#
# 用法:
#   ./scripts/build.sh [源码目录] [输出目录]
# 默认:
#   源码目录 = ./linux          (或 $LINUX_SRC)
#   输出目录 = ./build
# ============================================================================
set -euo pipefail

SRC="${1:-${LINUX_SRC:-$(cd "$(dirname "$0")/.." && pwd)/linux}}"
OUT="${2:-${LINUX_OUT:-$(cd "$(dirname "$0")/.." && pwd)/build}}"
JOBS="${JOBS:-$(nproc)}"
RELEASE_NAME="microsoft-standard-WSL2"

# ---------------------------------------------------------------------------
# 关键: LOCALVERSION 必须显式导出。
#
# scripts/setlocalversion 在「LOCALVERSION 未设置」且「有 tag 命中 HEAD」时,
# 会从 --short 分支输出一个 '+' (见 setlocalversion:115-121 与 201)。
# CONFIG_LOCALVERSION 无法抑制它 —— 只有设置 LOCALVERSION 环境变量才跳过该分支。
# 传空串即可: 名称由 CONFIG_LOCALVERSION 提供, 且不会追加任何后缀。
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

make O="$OUT" -j"$JOBS"
make O="$OUT" -j"$JOBS" modules

echo
echo "=== 构建完成 ==="
echo "内核镜像: $OUT/arch/x86/boot/bzImage"
echo "版本:     $(make -s O="$OUT" kernelrelease)"
