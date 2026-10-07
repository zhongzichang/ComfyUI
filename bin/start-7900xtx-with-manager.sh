#!/usr/bin/env bash

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# 开启 AOTriton Flash Attention 加速，并注入 ComfyUI 优化参数
AITER_TRITON_ONLY=1 \
COMFYUI_ENABLE_MIOPEN=1 \
FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE \
TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1 \
python ${SCRIPT_DIR}/../main.py \
  --enable-manager \
  --disable-mmap \
  --disable-smart-memory \
  --use-pytorch-cross-attention \
  --cache-none
