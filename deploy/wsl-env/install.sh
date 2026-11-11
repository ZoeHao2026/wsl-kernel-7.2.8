#!/usr/bin/env bash
# ============================================================================
# install.sh —— WSL 侧一键部署（必须 root）
#
# 装四件与「环境」相关的东西，都不需要重编内核：
#   1. /tmp/.X11-unix 启动竞态的兜底（约一半冷启动会让 GUI 全部失败）
#   2. zram(zstd) 压缩交换 + swappiness/page-cluster 微调（幂等、多发行版安全）
#   3. AppArmor/securityfs 启动顺序修复（保证 profile 在冷启动时能加载）
#   4. wsl-gpu 开关（Intel Arc 硬件加速，按需启用，默认关）
#
# 用法:
#   sudo ./install.sh              安装/更新全部
#   sudo ./install.sh --dry-run    只打印将要做什么
#   sudo ./install.sh --uninstall  卸载（只删本脚本装的文件）
#   sudo ./install.sh --status     查看当前状态
#
# 特点:
#   * **幂等** —— 重复运行安全，只覆盖内容不同的文件
#   * **可卸载** —— 只动它自己装的东西，不碰别人的配置
#   * 不安装新软件包；只依赖 systemd、util-linux(zramctl)、已装的内核模块
#
# 内核本身（bzImage / 模块盘 / .wslconfig）由 Windows 侧的 install.ps1 负责，
# 因为那些操作在 WSL 之外。两边可以独立运行。
# ============================================================================
set -uo pipefail

DRY=0
ACTION=install
for arg in "$@"; do
	case "$arg" in
		--dry-run)   DRY=1 ;;
		--uninstall) ACTION=uninstall ;;
		--status)    ACTION=status ;;
		-h|--help)   sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "未知参数: $arg（试 --help）" >&2; exit 2 ;;
	esac
done

# ---------------------------------------------------------------- 路径与来源
SRC="$(cd "$(dirname "$0")" && pwd)"
ASSETS="$SRC/assets"
[ -d "$ASSETS" ] || { echo "找不到资产目录: $ASSETS" >&2; exit 1; }

PROFILE=/etc/profile.d/50-wsl-display.sh
UNIT=/etc/systemd/system/wsl-x11-socket.service
HELPER=/usr/local/libexec/ensure-wsl-x11-socket.sh
ZRAM_UNIT=/etc/systemd/system/zram-wsl.service
ZRAM_HELPER=/usr/local/libexec/zram-wsl-setup
SYSCTL=/etc/sysctl.d/90-wsl-zram-sysctl.conf
SECURITYFS_UNIT=/etc/systemd/system/wsl-securityfs.service
APPARMOR_DROPIN=/etc/systemd/system/apparmor.service.d/20-wsl-boot.conf
GPUBIN=/usr/local/bin/wsl-gpu

changed=0
log()  { printf '%s\n' "$*"; }
act()  { if [ "$DRY" = 1 ]; then printf '  [dry-run] %s\n' "$*"; else printf '  %s\n' "$*"; fi; }

# 读内核配置项。注意**不要**写成 `zcat ... | grep -q`：
# 在本脚本的 pipefail 下，grep -q 找到匹配就退出，zcat 收到 SIGPIPE，
# 整条管道返回非 0，于是「明明有配置却被判定为不支持」。
kconfig() { zcat /proc/config.gz 2>/dev/null | grep -E "^$1=" ; }
kconfig_is() { [ "$(kconfig "$1")" = "$1=$2" ]; }

install_if_diff() {
	local src="$1" dst="$2" mode="$3"
	if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
		printf '  = 已是最新  %s\n' "$dst"
		return 1
	fi
	if [ "$DRY" = 1 ]; then
		printf '  [dry-run] 安装 %s -> %s (mode %s)\n' "$(basename "$src")" "$dst" "$mode"
		changed=1
		return 0
	fi
	install -D -m "$mode" "$src" "$dst" && printf '  + 已安装    %s\n' "$dst"
	changed=1
	return 0
}

need_root() {
	if [ "$(id -u)" != 0 ]; then
		echo "需要 root：请用 sudo $0 $*" >&2
		exit 1
	fi
}

# ============================================================ status
do_status() {
	echo "=== 1. X11 socket 兜底 ==="
	printf '  %-52s %s\n' "$PROFILE" "$([ -f "$PROFILE" ] && echo 已装 || echo 未装)"
	printf '  %-52s %s\n' "$HELPER" "$([ -x "$HELPER" ] && echo 已装 || echo 未装)"
	printf '  %-52s %s\n' "$UNIT" "$([ -f "$UNIT" ] && echo 已装 || echo 未装)"
	printf '  %-52s %s\n' "unit enabled/active" "$(systemctl is-enabled wsl-x11-socket.service 2>&1)/$(systemctl is-active wsl-x11-socket.service 2>&1)"
	printf '  %-52s %s\n' "/tmp/.X11-unix" "$(stat -c %F /tmp/.X11-unix 2>/dev/null || echo 缺失)"
	printf '  %-52s %s\n' "/tmp/.X11-unix/X0" "$([ -S /tmp/.X11-unix/X0 ] && echo 就绪 || echo '不可用（登录时由 profile.d 兜底）')"
	printf '  %-52s %s\n' "immutable 位" "$(lsattr -d /tmp/.X11-unix 2>/dev/null | awk '{print $1}' || echo -)"
	echo
	echo "=== 2. zram 压缩交换 ==="
	printf '  %-52s %s\n' "$ZRAM_UNIT" "$([ -f "$ZRAM_UNIT" ] && echo 已装 || echo 未装)"
	printf '  %-52s %s\n' "$ZRAM_HELPER" "$([ -x "$ZRAM_HELPER" ] && echo 已装 || echo 未装)"
	printf '  %-52s %s\n' "$SYSCTL" "$([ -f "$SYSCTL" ] && echo 已装 || echo 未装)"
	printf '  %-52s %s\n' "zram-wsl.service" "$(systemctl is-active zram-wsl.service 2>&1)"
	printf '  %-52s %s\n' "zramctl" "$(zramctl --noheadings 2>/dev/null | tr -s ' ' || echo 无设备)"
	printf '  %-52s %s\n' "vm.swappiness / page-cluster" "$(sysctl -n vm.swappiness 2>/dev/null) / $(sysctl -n vm.page-cluster 2>/dev/null)"
	echo
	echo "=== 3. AppArmor / securityfs ==="
	printf '  %-52s %s\n' "$SECURITYFS_UNIT" "$([ -f "$SECURITYFS_UNIT" ] && echo 已装 || echo 未装)"
	printf '  %-52s %s\n' "$APPARMOR_DROPIN" "$([ -f "$APPARMOR_DROPIN" ] && echo 已装 || echo 未装)"
	printf '  %-52s %s\n' "apparmor.service" "$(systemctl is-active apparmor.service 2>&1)"
	printf '  %-52s %s\n' "securityfs" "$(findmnt -n -o FSTYPE /sys/kernel/security 2>/dev/null || echo 未挂载)"
	printf '  %-52s %s\n' "loaded profiles" "$(aa-status 2>/dev/null | awk '/profiles are loaded/{print $1}' || echo -)"
	echo
	echo "=== 4. GPU 开关 ==="
	printf '  %-52s %s\n' "$GPUBIN" "$([ -x "$GPUBIN" ] && echo 已装 || echo 未装)"
	if [ -x "$GPUBIN" ]; then "$GPUBIN" status; fi
	echo
	echo "=== 内核能力检查 ==="
	printf '  %-52s %s\n' "uname -r" "$(uname -r)"
	printf '  %-52s %s\n' "CONFIG_ZRAM=m"        "$(kconfig_is CONFIG_ZRAM m && echo 支持 || echo 不支持)"
	printf '  %-52s %s\n' "CONFIG_ZRAM_BACKEND_ZSTD=y" "$(kconfig_is CONFIG_ZRAM_BACKEND_ZSTD y && echo 支持 || echo 不支持)"
	printf '  %-52s %s\n' "CONFIG_ZSWAP=y"       "$(kconfig_is CONFIG_ZSWAP y && echo 支持 || echo 不支持)"
}

# ============================================================ install
do_install() {
	need_root "$@"
	log "从 $ASSETS 安装到系统"
	echo
	echo "=== 1/4 X11 socket 启动竞态兜底 ==="
	install_if_diff "$ASSETS/50-wsl-display.sh"          "$PROFILE"   644
	install_if_diff "$ASSETS/ensure-wsl-x11-socket.sh"   "$HELPER"    755
	install_if_diff "$ASSETS/wsl-x11-socket.service"     "$UNIT"      644
	if [ "$DRY" = 1 ]; then
		act "systemctl daemon-reload；systemctl enable --now wsl-x11-socket.service"
	else
		systemctl daemon-reload
		# 2026-10-24 优化：本单元在 5/5 冷启动中把 /tmp/.X11-unix 修好，
		# systemd 也从 degraded 变为 running；因此改为默认启用。
		systemctl enable --now wsl-x11-socket.service >/dev/null 2>&1
		printf '  + 已启用    wsl-x11-socket.service\n'
	fi
	printf '  · 主力修复: %s\n' "$PROFILE"
	printf '    登录时若 :0 不通就改用 virtiofs 上的 socket；实测 11/11 冷启动可用\n'
	printf '  · 补充单元: wsl-x11-socket.service（当前 %s）\n' "$(systemctl is-enabled wsl-x11-socket.service 2>&1)"
	printf '    2026-10-24 优化版实测 5/5 冷启动可用；若仍失败，登录 shell 由 profile.d 兜底。\n'
	printf '  · /tmp/.X11-unix/X0 -> %s\n' "$([ -S /tmp/.X11-unix/X0 ] && echo 就绪 || echo '当前不可用（登录时由 profile.d 兜底）')"
	echo
	echo "=== 2/4 zram 压缩交换 ==="
	if ! kconfig_is CONFIG_ZRAM m && ! kconfig_is CONFIG_ZRAM y; then
		log "  ! 当前内核没有 CONFIG_ZRAM，跳过 zram（本仓库 7.3.4 配置里有）"
	else
		install_if_diff "$ASSETS/zram-wsl-setup.sh"       "$ZRAM_HELPER" 755
		install_if_diff "$ASSETS/zram-wsl.service"        "$ZRAM_UNIT" 644
		install_if_diff "$ASSETS/90-wsl-zram-sysctl.conf" "$SYSCTL"    644
		if [ "$DRY" = 1 ]; then
			act "systemctl enable --now zram-wsl.service；sysctl --system"
		else
			systemctl daemon-reload
			systemctl enable --now zram-wsl.service >/dev/null 2>&1
			sysctl --system >/dev/null 2>&1
			printf '  + 已启用    zram-wsl.service (%s)\n' "$(systemctl is-active zram-wsl.service 2>&1)"
			zramctl --noheadings 2>/dev/null | sed 's/^/    /'
		fi
	fi
	echo
	echo "=== 3/4 AppArmor / securityfs ==="
	install_if_diff "$ASSETS/wsl-securityfs.service" "$SECURITYFS_UNIT" 644
	if [ "$DRY" = 1 ]; then
		act "install -d $(dirname "$APPARMOR_DROPIN")"
	else
		install -d -m 755 "$(dirname "$APPARMOR_DROPIN")"
	fi
	install_if_diff "$ASSETS/apparmor-20-wsl-boot.conf" "$APPARMOR_DROPIN" 644
	if [ "$DRY" = 1 ]; then
		act "systemctl daemon-reload；systemctl enable --now wsl-securityfs.service；systemctl restart apparmor.service"
	else
		systemctl daemon-reload
		systemctl enable --now wsl-securityfs.service >/dev/null 2>&1 || true
		printf '  + wsl-securityfs.service %s\n' "$(systemctl is-active wsl-securityfs.service 2>&1)"
		systemctl restart apparmor.service >/dev/null 2>&1 || true
		printf '  + apparmor.service %s（%s 个 profile）\n' \
			"$(systemctl is-active apparmor.service 2>&1)" \
			"$(aa-status 2>/dev/null | awk '/profiles are loaded/{print $1}' || echo '?')"
	fi
	echo
	echo "=== 4/4 wsl-gpu 开关 ==="
	install_if_diff "$ASSETS/wsl-gpu" "$GPUBIN" 755
	printf '  · 用法: wsl-gpu status | on | off | test\n'
	echo
	if [ "$DRY" = 1 ]; then
		log "dry-run 结束，没有做任何修改。"
	elif [ "$changed" = 1 ]; then
		log "完成。已装/更新的项目见上面 '+' 行。"
		log "提示: 新开的登录 shell 才会读 profile.d；已开的 shell 可执行"
		log "      source /etc/profile.d/50-wsl-display.sh"
	else
		log "完成。所有项目已经是最新，无需改动。"
	fi
}

# ============================================================ uninstall
do_uninstall() {
	need_root "$@"
	log "卸载本脚本安装的内容（其它配置不动）"
	echo
	if [ "$DRY" = 1 ]; then
		for f in "$PROFILE" "$UNIT" "$HELPER" "$ZRAM_UNIT" "$ZRAM_HELPER" "$SYSCTL" "$SECURITYFS_UNIT" "$APPARMOR_DROPIN" "$GPUBIN"; do
			[ -e "$f" ] && act "删除 $f"
		done
		act "systemctl disable --now wsl-x11-socket.service zram-wsl.service wsl-securityfs.service"
		act "swapoff /dev/zram0（若在用）"
		act "chattr -i /tmp/.X11-unix（若被加了 immutable）"
		log "dry-run 结束。"
		return
	fi
	systemctl disable --now wsl-x11-socket.service >/dev/null 2>&1
	systemctl disable --now zram-wsl.service >/dev/null 2>&1
	systemctl disable --now wsl-securityfs.service >/dev/null 2>&1
	swapoff /dev/zram0 2>/dev/null || true
	for f in "$PROFILE" "$UNIT" "$HELPER" "$ZRAM_UNIT" "$ZRAM_HELPER" "$SYSCTL" "$SECURITYFS_UNIT" "$APPARMOR_DROPIN" "$GPUBIN"; do
		if [ -e "$f" ]; then rm -f "$f" && printf '  - 已删除    %s\n' "$f"; fi
	done
	# 解除 immutable，否则 /tmp/.X11-unix 之后无法被正常管理
	if lsattr -d /tmp/.X11-unix 2>/dev/null | grep -q -- '-i-'; then
		chattr -i /tmp/.X11-unix 2>/dev/null && printf '  - 已解除 immutable  %s\n' /tmp/.X11-unix
	fi
	systemctl daemon-reload
	sysctl --system >/dev/null 2>&1 || true
	log "完成。"
	log "注意: /tmp/.X11-unix 与 .wslconfig 的 memory= 不在卸载范围内 ——"
	log "      前者由 WSL 自己管理，后者请手动编辑 %USERPROFILE%\\.wslconfig。"
}

case "$ACTION" in
	install)   do_install ;;
	uninstall) do_uninstall ;;
	status)    do_status ;;
esac
