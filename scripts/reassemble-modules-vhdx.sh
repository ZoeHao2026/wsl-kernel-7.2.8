#!/usr/bin/env bash
# ============================================================================
# 从 release 分片重建 modules-7.2.8-microsoft-standard-WSL2.vhdx（Linux / WSL 侧）
#
# 用法:
#   ./reassemble-modules-vhdx.sh [输出路径]
#
# 为什么模块盘是分片的
# --------------------
# 本条网络到 uploads.github.com 的 POST 在约 16 MiB 处被对端重置（16 MiB 与
# 40 MiB 的测试体都在 ~16.7 MB 处断开），因此 243 MB 的模块盘无法整文件上传。
# 超过约 48 MiB 的附件都按 4 MiB 分片发布。
#
# 本脚本下载全部分片、逐片校验 SHA-256、拼接、再校验整体 SHA-256。
# 任一步失败即中止，不会留下一个看起来正常但实际损坏的 VHDX。
# ============================================================================
set -euo pipefail

REPO="${REPO:-ZoeHao2026/wsl-kernel-7.2.8}"
# TAG 留空 = 跟随最新 release；显式设置则固定到该版本
TAG="${TAG:-}"
PARTS="${PARTS:-58}"
PREFIX="modules-7.2.8-microsoft-standard-WSL2.vhdx.4m"
EXPECT_VHDX="89fe1d8d5af13c9a13b4311cc48ee63633ce55594dfcc528ad2520ce63cf0de3"

OUT="${1:-$PWD/modules-7.2.8-microsoft-standard-WSL2.vhdx}"

if [ -e "$OUT" ]; then
	printf '拒绝覆盖已存在的文件: %s\n' "$OUT" >&2
	exit 1
fi

for tool in curl sha256sum cat mktemp; do
	command -v "$tool" >/dev/null 2>&1 || { printf '缺少工具: %s\n' "$tool" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -n "$TAG" ]; then
	base="https://github.com/$REPO/releases/download/$TAG"
else
	base="https://github.com/$REPO/releases/latest/download"
fi

printf '=== 取分片校验值 ===\n'
curl -fSL --retry 3 -o "$work/PART4M-SHA256SUMS" "$base/PART4M-SHA256SUMS"

printf '=== 下载 %s 个分片 ===\n' "$PARTS"
for i in $(seq 0 $((PARTS - 1))); do
	name="$(printf '%s%02d' "$PREFIX" "$i")"
	dest="$work/$name"
	ok=0
	for attempt in 1 2 3 4; do
		if curl -fSL --retry 2 --retry-delay 2 -o "$dest" "$base/$name" 2>/dev/null; then
			ok=1
			break
		fi
		sleep $((2 * attempt))
	done
	[ "$ok" = 1 ] || { printf '分片下载失败: %s\n' "$name" >&2; exit 1; }
	printf '  %s\n' "$name"
done

printf '=== 逐片校验 SHA-256 ===\n'
( cd "$work" && sha256sum -c PART4M-SHA256SUMS )

printf '=== 拼接 ===\n'
# 按 part00..partNN 的顺序拼接；用 printf 生成名字，避免依赖 glob 的排序规则
: > "$work/merged.img"
for i in $(seq 0 $((PARTS - 1))); do
	cat "$work/$(printf '%s%02d' "$PREFIX" "$i")" >> "$work/merged.img"
done

actual="$(sha256sum "$work/merged.img" | awk '{print $1}')"
printf '输出 SHA-256: %s\n' "$actual"
if [ "$actual" != "$EXPECT_VHDX" ]; then
	printf '拼接结果与预期不符！\n  expected %s\n  actual   %s\n' "$EXPECT_VHDX" "$actual" >&2
	exit 1
fi

mv "$work/merged.img" "$OUT"
printf '✅ 校验通过: %s\n' "$OUT"
ls -la "$OUT"
printf '\n下一步 —— 在 %%USERPROFILE%%\\.wslconfig 里指向它（路径必须用正斜杠）。\n'
printf '若输出路径在 WSL 里，用 `wslpath -w "%s"` 取得 Windows 路径再填进 kernelModules。\n' "$OUT"
printf '然后 wsl --shutdown，重启后用 uname -r 确认内核确实换了。\n'
