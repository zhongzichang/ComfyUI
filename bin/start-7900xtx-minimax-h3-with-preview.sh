#!/usr/bin/env bash

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# 开启 AOTriton Flash Attention 加速，并注入 ComfyUI 优化参数
#
#  --enable-dynamic-vram ComfyUI 误以为你的显存不够用，在计算时频繁地在“显存 ↔ 内存”之间搬运
#  --disable-smart-memory 可以防止 ROCm 在每步卸载权重时产生 NaN 黑屏或噪音 Bug
#  --disable-mmap 能防止读取 20GB+ 大模型时引发的系统崩溃
#  --use-pytorch-cross-attention \
#  强迫 ComfyUI 采用最传统的 PyTorch 慢速常规注意力机制
#  --use-sage-attention 可以在画质毫无损失的前提下提高 2~4 倍的速度，适合 CUDA
#  --use-ck-attention 是新版 ComfyUI 专门为 AMD ROCm 引入的内核优化，能极大减少 Prompt 的前推时间
#  --fp32-vae 这个全局参数会将视频 VAE 也强制拉回 FP32 运行，这会导致视频解码阶段变得极其漫长
#  --preview-method taesd \
AITER_TRITON_ONLY=1 \
COMFYUI_ENABLE_MIOPEN=1 \
FLASH_ATTENTION_TRITON_AMD_ENABLE=TRUE \
TORCH_ROCM_AOTRITON_ENABLE_EXPERIMENTAL=1 \
python ${SCRIPT_DIR}/../main.py \
  --disable-mmap \
  --disable-smart-memory \
  --use-ck-attention  \
  --preview-method taesd \
  --cache-none
