#!/usr/bin/env bash
# ============================================================================
# validate-wsl-kernel.sh —— 采集自定义 WSL 内核的验证结果
#
# 用法:
#   ./scripts/validate-wsl-kernel.sh [输出文件]
#
# 只读：不修改系统配置、不重启、不写系统目录（除可选的输出文件）。
# 设计目标是让“这次内核到底有没有问题”可以用一段输出回答：
#   * 版本/启动日志/失败单元
#   * 模块、dxgkrnl、KVM、网络、WSLg、AppArmor、zram
#   * 与上一版基线相同的文件系统基准（可选，见 --no-bench）
# ============================================================================
set -uo pipefail

OUT="${1:-}"
RUN_BENCH=1
[ "${2:-}" = "--no-bench" ] && RUN_BENCH=0

log() { printf '%s\n' "$*"; }
sec() { printf '\n===== %s =====\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

exec > >(tee ${OUT:+"$OUT"}) 2>&1

sec "identity"
uname -a
uname -v
cat /etc/os-release 2>/dev/null | head -3
cat /proc/cmdline
date -Is

sec "boot health"
log "systemd: $(systemctl is-system-running 2>&1)"
systemctl --failed --no-legend --no-pager 2>&1 || true
log "boot: $(systemd-analyze 2>/dev/null | head -3 | tr '\n' ' ')"
if have journalctl; then
	log "journal corrupted messages this boot: $(journalctl -b --no-pager 2>/dev/null | grep -c 'corrupted or uncleanly' || true)"
fi
dmesg -l err,warn 2>/dev/null | tail -40 || true

sec "modules"
log "module count: $(find "/usr/lib/modules/$(uname -r)" -name '*.ko*' 2>/dev/null | wc -l)"
for m in zram zsmalloc ntfs3 squashfs erofs kvm_intel wireguard overlay nfs cifs exfat f2fs dm_crypt; do
	if modprobe -n -q "$m" 2>/dev/null; then log "OK  $m"; else log "NO  $m"; fi
done
lsmod 2>/dev/null | head -12 || true

sec "zram / swap / memory"
zramctl 2>/dev/null || true
swapon --show 2>/dev/null || true
free -h
sysctl vm.swappiness vm.page-cluster 2>/dev/null || true
log "zram resets this boot (Removed device lines): $(dmesg 2>/dev/null | grep -c 'zram: Removed device' || true)"

sec "devices"
for d in /dev/dxg /dev/kvm /dev/dri; do
	if [ -e "$d" ]; then log "$d present"; else log "$d absent"; fi
done
[ -r /sys/module/kvm_intel/parameters/nested ] && log "kvm nested=$(cat /sys/module/kvm_intel/parameters/nested)"
dmesg 2>/dev/null | grep -iE 'dxgkrnl|registering driver dxg|hv_vmbus: registering' | tail -5 || true

sec "preempt"
cat /sys/kernel/debug/sched/preempt 2>/dev/null || true
cat /sys/kernel/mm/lru_gen/enabled 2>/dev/null || true

sec "apparmor"
systemctl is-active apparmor 2>&1 || true
aa-status 2>/dev/null | head -4 || true
findmnt /sys/kernel/security 2>/dev/null || true

sec "network"
ip -br addr 2>/dev/null | head -8 || true
cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || true
wslinfo --networking-mode 2>/dev/null || true
getent hosts www.kernel.org 2>/dev/null | head -2 || true
curl -sI --max-time 10 https://www.kernel.org/ 2>/dev/null | head -1 || true

sec "gui"
if [ -S /tmp/.X11-unix/X0 ]; then log "/tmp/.X11-unix/X0 ready"; else log "/tmp/.X11-unix/X0 missing"; fi
if [ -S /mnt/wslg/.X11-unix/X0 ]; then log "/mnt/wslg/.X11-unix/X0 ready"; else log "/mnt/wslg/.X11-unix/X0 missing"; fi
if have xdpyinfo && [ -n "${DISPLAY:-}" ]; then xdpyinfo 2>/dev/null | head -5 || true; fi
if have pactl; then pactl info 2>/dev/null | head -6 || true; fi

sec "interop"
if [ -e /mnt/c/Windows/System32/cmd.exe ]; then log "/mnt/c interop path present"; fi
command -v powershell.exe >/dev/null 2>&1 && log "powershell.exe in PATH" || log "powershell.exe not in PATH (ok)"

sec "filesystem (quick)"
df -h / /tmp /mnt/c /mnt/d 2>/dev/null || true
findmnt -n -o TARGET,FSTYPE,SOURCE / /tmp /mnt/c /mnt/d 2>/dev/null || true

if [ "$RUN_BENCH" = 1 ] && [ -x "$(dirname "$0")/run-fs-bench.sh" ]; then
	sec "fs bench"
	"$(dirname "$0")/run-fs-bench.sh" "/tmp/bench-$(uname -r)-$(date +%Y%m%d-%H%M%S).txt" 2>&1 | tail -40 || true
fi

sec "done"
