#!/usr/bin/env bash
# 停止 ComfyUI（本套 ComfyUI 的 main.py 进程，TERM 不行就 KILL），并确认端口释放。
# 用法: bin/stop-comfyui.sh    [COMFY_PORT=8188]
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=comfyui-pids.sh
. "${SCRIPT_DIR}/comfyui-pids.sh"     # 提供 COMFY_ROOT + find_pids
PORT="${COMFY_PORT:-8188}"

pids=$(find_pids)
if [ -z "${pids}" ]; then
  echo "没有在跑的 ComfyUI（${COMFY_ROOT}）"
  exit 0
fi

echo "TERM ${pids}"
kill -TERM ${pids} 2>/dev/null || true
for _ in $(seq 1 15); do
  sleep 1
  remaining=$(find_pids)
  [ -z "${remaining}" ] && break
done
remaining=$(find_pids)
if [ -n "${remaining}" ]; then
  echo "KILL ${remaining}"
  kill -KILL ${remaining} 2>/dev/null || true
  sleep 1
fi

if ss -ltn 2>/dev/null | grep -q " ${PORT} "; then
  echo "警告：端口 ${PORT} 仍在监听，请检查"
  exit 1
fi
echo "已停止，端口 ${PORT} 已释放"
