#!/bin/sh
# ============================================================================
# zram-wsl-setup —— 幂等、多发行版安全的 zram 压缩交换初始化
#
# 为什么不是把命令直接写进 systemd unit
# ------------------------------------
# WSL2 的所有发行版共享同一个内核：swap 是全局状态，zram 设备也是全局的。
# 旧版 unit 无条件 `zramctl --reset /dev/zram0`，会在另一个发行版已经建立
# zram swap 时把它拆掉；旧版还挂到 swap.target，WSL 每个会话结束停止
# swap.target 时会把 zram swapoff + reset，下一次 wsl 命令再重建，
# 于是 dmesg 里出现反复的 "zram: Removed device / Added device"。
#
# 本脚本只做两件事：
#   1) 已经有任何 zram 设备在提供 swap —— 直接成功退出，什么都不动；
#   2) 没有 —— 按内存的 1/6 建一个 zstd zram 设备并 swapon（优先级 100）。
# 因此它可以被反复执行，也不会和其他发行版抢设备。
# ============================================================================
set -eu

# 没有 zram 模块时安静退出（裁剪内核/卸载场景）
/sbin/modprobe zram 2>/dev/null || exit 0

# 全局检查：任何 zram 设备已在 swap 中，就认为已经满足需求
if awk '$1 ~ /^\/dev\/zram[0-9]+$/ { found = 1 } END { exit !found }' /proc/swaps; then
	exit 0
fi

# 清理一个残留但未使用的 zram0（失败不致命）
/usr/sbin/zramctl --reset /dev/zram0 2>/dev/null || true

mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
size_kb=$((mem_kb / 6))
# 下限 512 MiB，上限 8 GiB（名义容量；zstd 实际占用远低于此）
[ "$size_kb" -lt 524288 ] && size_kb=524288
[ "$size_kb" -gt 8388608 ] && size_kb=8388608

dev=$(/usr/sbin/zramctl --find --size "${size_kb}K" --algorithm zstd 2>/dev/null) || exit 0
[ -n "$dev" ] || exit 0

/sbin/mkswap "$dev" >/dev/null
/sbin/swapon --priority 100 "$dev"
