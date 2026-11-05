#!/usr/bin/env bash
# 启动 ComfyUI —— RX 7900 XTX (gfx1100, ROCm)，只监听「本机回环 + Tailscale」
# 用法:  bin/start-7900xtx-tailscale.sh
#        COMFY_PORT=8189 bin/start-7900xtx-tailscale.sh      # 换端口
#        COMFY_LISTEN=127.0.0.1 bin/start-7900xtx-tailscale.sh   # 只留本机（临时断远程）
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COMFY_DIR=$(realpath -m "${SCRIPT_DIR}/..")
PORT="${COMFY_PORT:-8188}"

# ROCm 调优（同 start-7900xtx-v2.sh）
export FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE
export TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
export PINTO_DISABLE_NNPACK=1

# 监听地址：回环 + 当前 Tailscale 地址。
# Tailscale IP 由控制面分配、可能变，所以每次启动现取；地址不在本机网卡上时
# aiohttp 绑定会抛 EADDRNOTAVAIL 直接终止启动，因此只绑真实拿到的地址。
if [ -n "${COMFY_LISTEN:-}" ]; then
  LISTEN="${COMFY_LISTEN}"
else
  addrs=(127.0.0.1)
  if command -v tailscale >/dev/null 2>&1; then
    for fam in -4 -6; do
      ip=$(tailscale ip "$fam" 2>/dev/null | head -n1 || true)
      [ -n "${ip}" ] && addrs+=("${ip}")
    done
  fi
  LISTEN=$(IFS=,; echo "${addrs[*]}")
  if [ "${LISTEN}" = "127.0.0.1" ]; then
    echo "WARN: 取不到 Tailscale 地址（tailscale 没在跑？），本次只监听 127.0.0.1，远程访问不了。" >&2
  fi
fi

echo "listen = ${LISTEN}:${PORT}"

# 注意：ComfyUI 没有任何认证。这里只绑 Tailscale 网段（100.64.0.0/10、fd7a::/64），
# 等于只有你自己的 tailnet 节点能访问；局域网 192.168.1.x 已经不再监听。
# 要恢复纯局域网版：bin/start-7900xtx-v2.sh
exec "${COMFY_DIR}/venv/bin/python" "${COMFY_DIR}/main.py" \
  --listen "${LISTEN}" \
  --port "${PORT}" \
  --disable-mmap \
  --disable-smart-memory \
  --cache-none
