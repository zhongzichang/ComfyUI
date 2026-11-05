#!/usr/bin/env bash
# 启动 ComfyUI —— MiniMax H3 版：RX 7900 XTX (24 GB, gfx1100, ROCm) + 回环/Tailscale 监听
# 用法:  bin/start-7900xtx-tailscale-h3.sh
#        COMFY_PORT=8189 bin/start-7900xtx-tailscale-h3.sh
#        COMFY_EXTRA_FLAGS="--lowvram" bin/start-7900xtx-tailscale-h3.sh   # 追加参数
#        COMFY_SKIP_GPU_CHECK=1 bin/start-7900xtx-tailscale-h3.sh          # 跳过启动前自检
#
# 和 start-7900xtx-tailscale.sh 的差别只有两处，都是 H3 这套权重的尺寸逼出来的：
#
#   1) 抬锁页上限。H3 的文本编码器 qwen3vl_32b_int4 单文件 13.9 GB，DiT 19.5 GB。
#      systemd 给 user@1000.service 的 LimitMEMLOCK 是 8388608 KB，即 7.84 GB；
#      单次超过它的锁页分配在 ROCm 上直接返回 hipErrorOutOfMemory，报出来是
#      "CUDA error: out of memory"，看着像显存不够，其实是锁页额度不够。
#      这里把 soft limit 抬到 hard limit；抬不动就如实报，好让你知道这次多半会 OOM。
#   2) 不带 --cache-none。那个参数每次提示词都清空权重缓存，等于每轮从空显存重装
#      19.5 GB，峰值必须独立达标；H3 是「多套大权重轮流用」的流程，正好相反，
#      默认缓存能让加载器自己规划余量。
#
# 24 GB 显存装不下 DiT(19.5 GB) 与文本编码器(13.9 GB) 同时驻留，四套权重合计
# 36.6 GB。要跑顺还得在权重上取舍：换小一档的文本编码器，或让它留在 CPU 上编码。
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COMFY_DIR=$(realpath -m "${SCRIPT_DIR}/..")
PORT="${COMFY_PORT:-8188}"

# ROCm 调优（同 start-7900xtx-tailscale.sh）
export FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE
export TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
export PINTO_DISABLE_NNPACK=1

# 锁页上限：soft 抬到 hard，hard 不是 unlimited 时只能抬到 hard（非 root 抬不了 hard）
soft=$(ulimit -l); hard=$(ulimit -Hl)
if [ "${soft}" != "unlimited" ]; then
  if [ "${hard}" = "unlimited" ]; then ulimit -l unlimited || true
  else ulimit -l "${hard}" 2>/dev/null || true; fi
fi
soft=$(ulimit -l)
if [ "${soft}" = "unlimited" ]; then
  echo "memlock = unlimited"
else
  echo "memlock = $((soft / 1024)) MB (soft) / ${hard} (hard)"
  echo "WARN: 锁页上限不足，13.9 GB 的文本编码器搬上卡会报成 out of memory。" >&2
  echo "      抬法：/etc/systemd/system.conf 里 DefaultLimitMEMLOCK=infinity，重启会话后生效。" >&2
fi

# 启动前花十几秒确认计算路径是活的：睡眠/唤醒后 amdgpu 复位过，40 KB 都分配不了，
# 这时起服务只会一路 OOM，日志里长得和显存不够一模一样。
if [ "${COMFY_SKIP_GPU_CHECK:-0}" != "1" ]; then
  echo "gpu check = 探测中（导入 torch 要十几秒，跳过用 COMFY_SKIP_GPU_CHECK=1）"
  if ! timeout 180 "${COMFY_DIR}/venv/bin/python" - <<'PYEOF'
import torch
free, total = torch.cuda.mem_get_info(0)
print("gpu = 显存空闲 %.2f / %.2f GB" % (free / 2**30, total / 2**30))
torch.zeros((1, 1, 8, 64), dtype=torch.float16, device="cuda")
torch.cuda.synchronize()
torch.zeros(1, device="cuda").add_(1).item()
print("gpu = 40 KB 分配通过，计算路径可用")
PYEOF
  then
    echo "ERROR: 显卡现在不可用（40 KB 都分配不了）。空闲显存是够的，这条失败说明设备状态坏了，" >&2
    echo "       多半是睡眠/唤醒后 amdgpu 复位过：先重启机器（或重载 amdgpu）再启动。" >&2
    exit 3
  fi
fi

# 监听地址：回环 + 当前 Tailscale 地址（同 start-7900xtx-tailscale.sh）。
# Tailscale IP 由控制面分配、会变，所以每次现取；地址不在本机网卡上时 aiohttp
# 绑定会抛 EADDRNOTAVAIL，因此只绑真实拿到的。
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

flags=(--listen "${LISTEN}" --port "${PORT}" --disable-mmap --disable-smart-memory)
# 故意不加引号展开：这里只放 --lowvram 这类不含空格的参数
[ -n "${COMFY_EXTRA_FLAGS:-}" ] && flags+=(${COMFY_EXTRA_FLAGS})
echo "listen = ${LISTEN}:${PORT}"
echo "flags = ${flags[*]}"

# 注意：ComfyUI 没有任何认证。只绑 Tailscale 网段（100.64.0.0/10、fd7a::/64），
# 等于只有自己的 tailnet 节点能访问；局域网 192.168.1.x 不监听。
exec "${COMFY_DIR}/venv/bin/python" "${COMFY_DIR}/main.py" "${flags[@]}"
