#!/usr/bin/env bash
# 共享小函数：找出「本套 ComfyUI」的 main.py 进程 pid。
# 判定方式：命令行里含 <本目录的父目录>/main.py，或者进程 cwd 就是该目录且在跑 main.py。
# 之所以不用 comfy-cli 的记录：多地址 --listen（逗号分隔）会让它的 background 记录变成
# ('127.0.0.1,100.64.0.3', 8188, pid)，它按逗号切字符串，解析直接 ValueError。
COMFY_ROOT=$(realpath -m "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")

find_pids() {
  local pid cmd cwd
  for pid in $(pgrep -f 'main\.py' 2>/dev/null || true); do
    [ "${pid}" = "$$" ] && continue
    [ -r "/proc/${pid}/cmdline" ] || continue
    cmd=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null) || continue
    case "${cmd}" in *"${COMFY_ROOT}/main.py"*) echo "${pid}"; continue ;; esac
    case "${cmd}" in *main.py*) ;; *) continue ;; esac
    cwd=$(readlink -f "/proc/${pid}/cwd" 2>/dev/null || true)
    [ "${cwd}" = "${COMFY_ROOT}" ] && echo "${pid}"
  done | sort -un
}
