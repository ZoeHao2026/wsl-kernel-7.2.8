# /etc/profile.d/50-wsl-display.sh
#
# 为什么需要它
# ------------
# WSLg 的 X11 socket 实际在 /mnt/wslg/.X11-unix/X0，而客户端默认按
# DISPLAY=:0 去找 /tmp/.X11-unix/X0。那条路径依赖一次竞态：
#
#   WSL 生成的 wslg.service 执行
#       mount -o bind,ro,X-mount.mkdir -t none /mnt/wslg/.X11-unix /tmp/.X11-unix
#   但它只声明 After=tmp.mount，实测会抢在 /tmp 的 tmpfs 就位之前跑完，
#   于是挂载点被 tmpfs 盖住，留下「mount 表里有、文件系统里没有」的坏态。
#
# 本机实测：10 次冷启动里约一半失败。坏态下所有走 :0 的 GUI 程序报
# "couldn't connect to display :0"。
#
# 本脚本做什么
# ------------
# 如果 /tmp/.X11-unix/X0 可用，什么都不做（保持 WSL 的默认行为）。
# 如果不可用但 /mnt/wslg/.X11-unix/X0 存在，就把 DISPLAY 指向后者。
# 那个路径由 virtiofs 提供，不受 /tmp 的 tmpfs 竞态影响，因此是确定的。
#
# 配套：wsl-x11-socket.service 会在启动时尽力把 /tmp/.X11-unix 修好，
# 让不读取 profile 的场景（systemd 用户单元、容器、IDE 后端）也能用。
# 两者互不冲突：这里只在 :0 真的不通时才改写。
if [ -n "${WSL_DISTRO_NAME:-}${WSL_INTEROP:-}" ]; then
	if [ -S /mnt/wslg/.X11-unix/X0 ] && [ ! -S /tmp/.X11-unix/X0 ]; then
		DISPLAY=unix:/mnt/wslg/.X11-unix/X0
		export DISPLAY
	fi
fi
