#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh —— WSL 侧一条命令取回 deploy 包并运行安装器
#
# 用法（不用先克隆仓库）:
#   curl -fsSL https://raw.githubusercontent.com/ZoeHao2026/wsl-kernel-7.2.8/main/deploy/bootstrap.sh \
#     | sudo bash
#
# 追加参数会原样转发给 install.sh:
#   ... | sudo bash -s -- --status
#
# 环境变量（正常情况不需要动，主要给本项目的自测用）:
#   DSH_BOOTSTRAP_URL    覆盖部署包地址
#   DSH_BOOTSTRAP_DIR    指定解包目录（默认 mktemp）
#   DSH_BOOTSTRAP_KEEP   设为 1 则保留解包目录
# ============================================================================
set -euo pipefail

REPO="${REPO:-ZoeHao2026/wsl-kernel-7.2.8}"
TAG="${TAG:-v7.2.8-wsl-kernel.2}"

if [ -n "${DSH_BOOTSTRAP_URL:-}" ]; then
	URL="$DSH_BOOTSTRAP_URL"
else
	URL="https://github.com/$REPO/releases/download/$TAG/wsl-kernel-deploy.tar.gz"
fi

if [ -n "${DSH_BOOTSTRAP_DIR:-}" ]; then
	WORK="$DSH_BOOTSTRAP_DIR"
	mkdir -p "$WORK"
	CLEANUP=0
else
	WORK="$(mktemp -d /tmp/wsl-kdeploy.XXXXXX)"
	CLEANUP=1
fi
[ "${DSH_BOOTSTRAP_KEEP:-0}" = "1" ] && CLEANUP=0

echo "WSL 内核 —— 一条命令引导安装"
echo "  部署包: $URL"
echo "  解包到: $WORK"
echo

echo "=== 下载 ==="
TGZ="$WORK/bundle.tar.gz"
if ! curl -fsSL --retry 3 -o "$TGZ" "$URL"; then
	echo "下载失败：$URL" >&2
	echo "（检查网络或代理；也可以改用 git clone 后运行 deploy/wsl-env/install.sh）" >&2
	exit 1
fi
size=$(wc -c < "$TGZ")
echo "  收到 $size 字节"
if [ "$size" -lt 1024 ]; then
	echo "下载内容过小，可能拿到了错误页面而不是压缩包" >&2
	exit 1
fi
# gzip 魔数校验：避免把代理的错误页当成 tar
if [ "$(od -An -tx1 -N2 "$TGZ" | tr -d ' ')" != "1f8b" ]; then
	echo "下载的不是 gzip 压缩包（魔数校验失败），检查 URL 或代理" >&2
	exit 1
fi
echo "  压缩包校验通过"

echo "=== 解包 ==="
tar xzf "$TGZ" -C "$WORK"
echo "  完成: $WORK"

INSTALL="$WORK/deploy/wsl-env/install.sh"
if [ ! -f "$INSTALL" ]; then
	INSTALL="$(find "$WORK" -name install.sh -path '*wsl-env*' | head -1 || true)"
fi
[ -n "$INSTALL" ] && [ -f "$INSTALL" ] || { echo "包里找不到 wsl-env/install.sh" >&2; exit 1; }

# 从管道进来的脚本没有 \\r；但若用户是从 Windows 侧另存为再传入，可能有
sed -i 's/\r$//' "$INSTALL" 2>/dev/null || true
chmod +x "$INSTALL"

echo "=== 运行 ==="
echo "  $INSTALL $*"
echo
bash "$INSTALL" "$@"
rc=$?

if [ "$CLEANUP" = 1 ]; then
	rm -rf "$WORK"
else
	echo "已保留: $WORK"
fi

exit "$rc"
