#!/bin/sh
# ============================================================================
# 尽力把 /tmp/.X11-unix/X0 修回来 —— 可选，默认不启用。
#
# 必读：主力修复不在这里
# ----------------------
# 真正确定生效的是 /etc/profile.d/50-wsl-display.sh（登录时把 DISPLAY 指向
# virtiofs 上的 /mnt/wslg/.X11-unix/X0，实测 11 次冷启动 11 次可用）。
# 本脚本只是给「不读 profile 的上下文」做补充，而且**本机实测它并不可靠**：
#
#   在 10 次冷启动里，只有约一半能被执行到。原因是 WSL 的启动并不走
#   systemd 的常规目标序列 —— 实测 multi-user.target / sysinit.target /
#   graphical.target 在服务被拉起时都已经是 active，所以无论
#   WantedBy= 挂到哪个目标上都不能保证触发。
#
# 因此上游把它做成「默认禁用、按需手动」：
#   sudo systemctl enable --now wsl-x11-socket.service
# 想碰运气时可以开；要确定可用，请依赖 profile.d，或者直接让程序用
#   DISPLAY=unix:/mnt/wslg/.X11-unix/X0
#
# 背景（为什么这条路径会丢）
# --------------------------
# WSL 生成的 wslg.service 执行
#     mount -o bind,ro,X-mount.mkdir -t none /mnt/wslg/.X11-unix /tmp/.X11-unix
# 但它只声明 After=tmp.mount，而 /tmp 本身是 tmp.mount 挂上来的 tmpfs。
# 当 mount(8) 抢在 tmpfs 就位之前跑完，挂载点建在 rootfs 的 /tmp 上，
# 随后被 tmpfs 整个盖住 —— mount 表里有记录、文件系统里没有这个路径。
#
# 本脚本幂等：已可用就不动（不覆盖 WSL 自己那份只读 bind 挂载）。
# 只报告不失败：这是锦上添花，不该让启动变成 failed。
# ============================================================================
set -u

SOCK=/mnt/wslg/.X11-unix/X0
TARGET=/tmp/.X11-unix

if [ ! -S "$SOCK" ]; then
	echo "WSLg socket $SOCK 不存在，跳过"
	exit 0
fi

if [ -S "$TARGET/X0" ]; then
	echo "$TARGET/X0 已可用，无需处理"
	exit 0
fi

if [ -L "$TARGET" ]; then
	echo "$TARGET 已是符号链接 -> $(readlink "$TARGET")"
	exit 0
fi

if [ -d "$TARGET" ]; then
	if [ -z "$(ls -A "$TARGET" 2>/dev/null)" ] && rmdir "$TARGET" 2>/dev/null; then
		:
	else
		# 非空目录，或是被 tmpfs 盖住的残留挂载点：无法直接替换，改为叠加绑定
		if mount --bind /mnt/wslg/.X11-unix "$TARGET" 2>/dev/null; then
			echo "已用 bind 修复 $TARGET"
			exit 0
		fi
		echo "无法替换目录 $TARGET（既非空也 bind 不上），跳过"
		exit 0
	fi
fi

if ln -sfn /mnt/wslg/.X11-unix "$TARGET" 2>/dev/null; then
	echo "已创建符号链接 $TARGET -> /mnt/wslg/.X11-unix"
else
	echo "创建符号链接失败：$TARGET"
fi
exit 0
