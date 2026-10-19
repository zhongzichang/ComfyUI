#!/usr/bin/env bash
# 启动 ComfyUI —— RX 7900 XTX (gfx1100, ROCm) 修订版
#
# 与原 start-7900xtx.sh 的差异：
#   1. 固定使用 venv 里的 python，不再依赖 PATH
#   2. 删除对本机无效的环境变量：
#        HSA_OVERRIDE_GFX_VERSION=11.0.0   7900 XTX 本身就是 gfx1100，ROCm 原生支持，无需伪装
#        AITER_TRITON_ONLY=1               venv 中未安装 aiter 包，变量不生效
#        COMFYUI_ENABLE_MIOPEN=1           ROCm 版 PyTorch 默认走 MIOpen，非 ComfyUI 开关
#   3. 注释只保留实际生效的内容，避免与命令行脱节

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
COMFY_DIR="${SCRIPT_DIR}/.."

# 注意力加速：Triton flash attention 后端（venv 已装 triton-rocm）
export FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE
# 注意力加速：torch ROCm 构建内置的 AOTriton 内核
export TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1
# 关闭 CPU NNPACK 推理库，避免干扰
export PINTO_DISABLE_NNPACK=1

exec "${COMFY_DIR}/venv/bin/python" "${COMFY_DIR}/main.py" \
  --listen 0.0.0.0 \
  --disable-mmap \
  --disable-smart-memory \
  --cache-none

# 参数说明（均为实际生效项）：
#   --listen 0.0.0.0       允许局域网访问。注意：ComfyUI 无认证，局域网内任何人都能操作。
#                          只在本机使用时改为 --listen 127.0.0.1
#   --disable-mmap         防止读取 20GB+ 大模型时引发系统崩溃
#   --disable-smart-memory 防止 ROCm 逐步卸载权重时产生 NaN 黑图/噪音
#   --cache-none           禁用缓存，避免陈旧缓存问题（重复跑同一图会稍慢）
#
# 备选参数（需要时手动加到上面，曾调研过但默认不启用）：
#   --enable-dynamic-vram      显存不足时自动在显存/内存间搬运（本机 24GB 一般用不上）
#   --use-pytorch-cross-attention  退回 PyTorch 常规注意力（注意力出问题时排障用）
#   --fp32-vae                 VAE 强制 FP32（会让视频解码极慢，慎开）
