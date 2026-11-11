#!/bin/sh
# ============================================================================
# 尽力把 /tmp/.X11-unix 修成可用状态（由 wsl-x11-socket.service 调用）。
#
# 背景
# ----
# WSL 生成的 wslg.service 执行
#     mount -o bind,ro,X-mount.mkdir -t none /mnt/wslg/.X11-unix /tmp/.X11-unix
# 但它只声明 After=tmp.mount，而 /tmp 本身是 tmp.mount 挂上来的 tmpfs。
# 当 mount(8) 抢在 tmpfs 就位之前跑完，挂载点建在 rootfs 的 /tmp 上，
# 随后被 tmpfs 整个盖住 —— mount 表里有记录、文件系统里没有这个路径。
# 反过来，如果本单元在 WSL 的挂载已经就位之后仍然做一次 bind，就会在
# /tmp/.X11-unix 上叠出第二层挂载；关机时 systemd 要逐层卸载，容易卡住。
#
# 本脚本的处理顺序：
#   1. 已经可用：把叠加的多余挂载收掉，只保留一层；
#   2. 不可用：清掉所有残留/坏的挂载，再重建一层（符号链接或 bind）；
#   3. 任何失败都只报告不退出非零 —— 这是锦上添花，不该让启动变 failed。
#
# 注意：主力修复仍是 /etc/profile.d/50-wsl-display.sh（登录时把 DISPLAY
# 指向 virtiofs 上的 /mnt/wslg/.X11-unix/X0）。本单元覆盖不读 profile 的
# 上下文（systemd 用户单元、容器、IDE 后端）。
# ============================================================================
set -u

SOCK=/mnt/wslg/.X11-unix/X0
TARGET=/tmp/.X11-unix

# /proc/mounts 里 /tmp/.X11-unix 还有几层挂载
mounts() {
	awk '$2 == "/tmp/.X11-unix" { n++ } END { print n + 0 }' /proc/mounts
}

if [ ! -S "$SOCK" ]; then
	echo "WSLg socket $SOCK 不存在，跳过"
	exit 0
fi

# 1) 已经可用：收掉叠加的多余层
if [ -S "$TARGET/X0" ]; then
	while [ "$(mounts)" -gt 1 ]; do
		umount -l "$TARGET" 2>/dev/null || break
	done
	if [ -S "$TARGET/X0" ]; then
		echo "$TARGET/X0 已可用（挂载层数 $(mounts)）"
		exit 0
	fi
fi

# 2) 清掉所有残留层（lazy 卸载不会阻塞）
while mountpoint -q "$TARGET" 2>/dev/null; do
	umount -l "$TARGET" 2>/dev/null || break
done

# 3) 符号链接已经存在就直接用
if [ -L "$TARGET" ]; then
	echo "$TARGET 已是符号链接 -> $(readlink "$TARGET")"
	exit 0
fi

# 4) 空目录：删掉后建符号链接
if [ -d "$TARGET" ] && [ -z "$(ls -A "$TARGET" 2>/dev/null)" ]; then
	rmdir "$TARGET" 2>/dev/null || true
fi
if [ ! -e "$TARGET" ]; then
	if ln -sfn /mnt/wslg/.X11-unix "$TARGET" 2>/dev/null; then
		echo "已创建符号链接 $TARGET -> /mnt/wslg/.X11-unix"
		exit 0
	fi
fi

# 5) 目录非空（或链接创建失败）：只叠加一层 bind
if mkdir -p "$TARGET" 2>/dev/null && mount --bind /mnt/wslg/.X11-unix "$TARGET" 2>/dev/null; then
	echo "已用 bind 修复 $TARGET（挂载层数 $(mounts)）"
	exit 0
fi

echo "无法修复 $TARGET（既非空也 bind 不上），跳过"
exit 0
