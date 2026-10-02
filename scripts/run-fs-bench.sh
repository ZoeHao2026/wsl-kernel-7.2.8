#!/usr/bin/env bash
# ============================================================================
# WSL 文件系统基准脚本 —— 冻结口径, 用于对比内核配置改动前后的表现。
#
# 用法:
#   ./scripts/run-fs-bench.sh [输出文件]
#
# 默认输出到标准输出; 给了文件则同时写入文件。
#
# 为什么这样测
# ------------
# 本脚本刻意把「顺序吞吐」和「元数据每操作开销」分开测, 因为两者在本机上差
# 两个数量级: /mnt/* 的 9P 挂载顺序读写约 200 MB/s, 而单文件创建要毫秒级;
# 内核配置改动影响的是后者, 只测吞吐会看不到任何变化。
#
# 注意
# ----
# ext4 一栏用 oflag=direct/iflag=direct 绕开页缓存, 9P 不支持 O_DIRECT 所以
# 不传该选项, 两者并不完全对称 —— 这里测的是「各自最优路径下的实际表现」,
# 与 Microsoft Learn 文档给用户的建议口径一致。
# ============================================================================
set -uo pipefail

OUT="${1:-}"
EXT4_DIR="${EXT4_DIR:-/tmp/dsh-fs-bench}"
P9_DIR="${P9_DIR:-/mnt/d/dsh-fs-bench}"
FILES="${FILES:-300}"
SEQ_MB="${SEQ_MB:-512}"
P9_SEQ_MB="${P9_SEQ_MB:-512}"

_log() {
	if [ -n "$OUT" ]; then printf '%s\n' "$*" | tee -a "$OUT"; else printf '%s\n' "$*"; fi
}
[ -n "$OUT" ] && : > "$OUT"

ms_now() { date +%s%N; }
ms_diff() { echo $(( ($2 - $1) / 1000000 )); }

_log "=============================================================="
_log "WSL 文件系统基准"
_log "时间:     $(date -Is)"
_log "内核:     $(uname -r)"
_log "机器:     $(nproc) vCPU / $(free -g | awk '/^Mem:/{print $2}') GiB RAM"
_log "=============================================================="

# ---------------------------------------------------------------- 内核状态
_log ""
_log "--- 内核状态 ---"
_log "cmdline:  $(cat /proc/cmdline)"
if [ -r /proc/config.gz ]; then
		for k in CONFIG_NR_CPUS= CONFIG_MAXSMP CONFIG_SCHEDSTATS CONFIG_LATENCYTOP \
		 CONFIG_SLUB_DEBUG CONFIG_PAGE_POISONING CONFIG_ZSWAP= CONFIG_LRU_GEN= \
		 CONFIG_ZRAM= CONFIG_CRYPTO_ZSTD=; do
		# 只打印真正命中的行; 未命中时 grep 退出码非 0, 用 || true 避免 set -e
		matched="$(zcat /proc/config.gz | grep -E "^(# )?${k}" | head -2 | tr '\n' ' ' || true)"
		[ -n "${matched// /}" ] && _log "  $matched"
	done
else
	_log "  (/proc/config.gz 不可读, 跳过)"
fi
_log "percpu:   $(grep -i '^Percpu' /proc/meminfo)"
_log "schedstats: $(cat /proc/sys/kernel/sched_schedstats 2>/dev/null || echo n/a)"
_log "zswap:    $(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo 'not built in')"

# ---------------------------------------------------------------- 顺序吞吐
_log ""
_log "--- 顺序吞吐 (dd) ---"

_seq_ext4() {
	local f="$EXT4_DIR/seq.bin"
	mkdir -p "$EXT4_DIR"
	_log "[ext4 $EXT4_DIR] 写 ${SEQ_MB}MiB (direct):"
	dd if=/dev/zero of="$f" bs=1M count="$SEQ_MB" oflag=direct 2>&1 | tail -1 | sed 's/^/    /' | tee -a "${OUT:-/dev/null}"
	sync
	_log "[ext4 $EXT4_DIR] 读 ${SEQ_MB}MiB (direct):"
	dd if="$f" of=/dev/null bs=1M iflag=direct 2>&1 | tail -1 | sed 's/^/    /' | tee -a "${OUT:-/dev/null}"
	rm -f "$f"
}

_seq_p9() {
	local f="$P9_DIR/seq.bin"
	if ! mkdir -p "$P9_DIR" 2>/dev/null; then
		_log "[9p $P9_DIR] 目录不可写, 跳过"
		return
	fi
	_log "[9p $P9_DIR] 写 ${P9_SEQ_MB}MiB:"
	dd if=/dev/zero of="$f" bs=1M count="$P9_SEQ_MB" 2>&1 | tail -1 | sed 's/^/    /' | tee -a "${OUT:-/dev/null}"
	_log "[9p $P9_DIR] 读 ${P9_SEQ_MB}MiB:"
	dd if="$f" of=/dev/null bs=1M 2>&1 | tail -1 | sed 's/^/    /' | tee -a "${OUT:-/dev/null}"
	rm -f "$f"
}

_seq_ext4
_seq_p9

# ------------------------------------------------------------ 元数据每操作
_meta() {
	local label="$1" dir="$2"
	if ! mkdir -p "$dir" 2>/dev/null; then
		_log "[$label] 目录不可用, 跳过"
		return
	fi
	local t0 t1
	t0=$(ms_now)
	for i in $(seq 1 "$FILES"); do : > "$dir/f$i"; done
	t1=$(ms_now)
	local create
	create=$(ms_diff "$t0" "$t1")

	t0=$(ms_now)
	for i in $(seq 1 "$FILES"); do stat -c %s "$dir/f$i" > /dev/null; done
	t1=$(ms_now)
	local statm
	statm=$(ms_diff "$t0" "$t1")

	t0=$(ms_now)
	ls -1 "$dir" > /dev/null
	t1=$(ms_now)
	local readdir
	readdir=$(ms_diff "$t0" "$t1")

	t0=$(ms_now)
	for i in $(seq 1 "$FILES"); do rm -f "$dir/f$i"; done
	t1=$(ms_now)
	local unlink
	unlink=$(ms_diff "$t0" "$t1")

	_log "[$label] $FILES 个文件: create=${create}ms ($(awk -v a="$create" -v b="$FILES" 'BEGIN{printf "%.3f", a/b}')ms/file) stat=${statm}ms readdir=${readdir}ms unlink=${unlink}ms ($(awk -v a="$unlink" -v b="$FILES" 'BEGIN{printf "%.3f", a/b}')ms/file)"
	rm -rf "$dir"
}

_log ""
_log "--- 元数据操作 (每 $FILES 个文件, 单位 ms) ---"
_meta "ext4" "$EXT4_DIR/meta"
_meta "9p  " "$P9_DIR/meta"

_log ""
_log "=== 基准结束 ==="
