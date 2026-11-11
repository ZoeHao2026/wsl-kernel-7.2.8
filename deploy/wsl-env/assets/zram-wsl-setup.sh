#!/bin/sh
# ============================================================================
# zram-wsl-setup —— 幂等、多发行版安全的 zram 压缩交换初始化
#
# 为什么这么复杂
# --------------
# WSL2 的所有发行版共享同一个内核：swap 是全局状态，zram 设备也是全局的。
# 而且 WSL 在「会话结束」时不走完整的关机流程，会停掉 multi-user/swap 目标，
# 下一次 `wsl` 命令再把它们拉起来；zram 设备本身不会消失，但 swap 可能被关掉。
# 因此本脚本必须做到：
#   1) 任何发行版已经建立了 zram swap —— 直接成功退出，绝不能碰别人的设备；
#   2) 没有 zram swap —— **复用**一个已存在但未使用的 zram 设备，而不是
#      每次 `--find` 都创建新编号（否则 zram1、zram2…… 会不断累积）；
#   3) 多个发行版可能同时启动 —— 用 /mnt/wsl 上的 flock 串行化。
#
# 踩坑记录：`/proc/swaps` 里 zram 交换的写法有三种：`zram0`、`/zram0`、
# `/dev/zram0`（取决于 swapon 时传入的路径）。只匹配其中一种会导致幂等检查
# 失效，进而不断新建设备。本版三种都匹配。
# ============================================================================
set -eu

# 没有 zram 模块时安静退出（裁剪内核/卸载场景）
/sbin/modprobe zram 2>/dev/null || exit 0

zram_swap_exists() {
	awk '$1 ~ /^(\/dev\/|\/)?zram[0-9]+$/ { found = 1 } END { exit !found }' /proc/swaps
}

# 全局锁：/mnt/wsl 是 WSL 各发行版共享的 tmpfs；挂不上时退回 /run
lock=/mnt/wsl/.zram-wsl.lock
if ! : >>"$lock" 2>/dev/null; then
	lock=/run/zram-wsl.lock
	: >>"$lock" 2>/dev/null || exit 0
fi
exec 9>"$lock"
flock -w 5 9 || exit 0

# 已经有**可用**的 zram swap —— 什么都不动。
# 旧版本可能把 swap 记成 /zramN（没有 /dev 前缀），或设备已被 reset 但 swap
# 记录还在；这两种情况下 zramctl 不会显示 [SWAP]，需要先 swapoff 再重建。
if zram_swap_exists && /usr/sbin/zramctl --noheadings -o MOUNTPOINT 2>/dev/null | grep -q '\[SWAP\]'; then
	exit 0
fi

# 清掉残留/旧命名的 zram swap（设备路径和原路径各试一次）
for name in $(awk '$1 ~ /^(\/dev\/|\/)?zram[0-9]+$/ { print $1 }' /proc/swaps); do
	swapoff "/dev/${name##*/}" 2>/dev/null || swapoff "$name" 2>/dev/null || true
done

mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
size_kb=$((mem_kb / 6))
# 下限 512 MiB，上限 8 GiB（名义容量；zstd 实际占用远低于此）
[ "$size_kb" -lt 524288 ] && size_kb=524288
[ "$size_kb" -gt 8388608 ] && size_kb=8388608

# 清掉未参与 swap 的残留设备，避免 zram0/1/2... 编号累积
for d in /dev/zram*; do
	[ -e "$d" ] || continue
	name=${d##*/}
	if grep -qE "^(\/dev\/|\/)?${name} " /proc/swaps; then
		continue
	fi
	/usr/sbin/zramctl --reset "$d" 2>/dev/null || true
done

# 优先复用已存在、且未参与 swap 的 zram 设备；`zramctl --size` 会重置它
dev=""
for d in /dev/zram*; do
	[ -e "$d" ] || continue
	name=${d##*/}
	if grep -qE "^(\/dev\/|\/)?${name} " /proc/swaps; then
		continue
	fi
	if /usr/sbin/zramctl --size "${size_kb}K" --algorithm zstd "$d" 2>/dev/null; then
		dev="$d"
		break
	fi
done

# 没有可复用的设备才创建；--find 返回的可能是裸名字，统一补 /dev/
if [ -z "$dev" ]; then
	dev=$(/usr/sbin/zramctl --find --size "${size_kb}K" --algorithm zstd 2>/dev/null) || exit 0
	[ -n "$dev" ] || exit 0
	case "$dev" in
		/dev/*) ;;
		*) dev="/dev/$dev" ;;
	esac
fi

/sbin/mkswap "$dev" >/dev/null
# swapon 失败（例如另一个发行版刚好抢先）不算错误
/sbin/swapon --priority 100 "$dev" 2>/dev/null || true
exit 0
