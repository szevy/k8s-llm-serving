#!/usr/bin/env bash
# Reproduce the quantised model artifact from scratch:
# download FP16 weights, convert to GGUF, quantise to Q4_K_M.
# Requires: docker, huggingface_hub (pip install -U huggingface_hub).
# Output: quantisation/qwen-q4_k_m.gguf (~380MB), which the Dockerfile copies into the image.
set -euo pipefail

mkdir -p quantisation

echo "==> Step 1: download the FP16 model (~1GB)"
hf download Qwen/Qwen2.5-0.5B-Instruct --local-dir quantisation/qwen-fp16

echo "==> Step 2: convert HuggingFace format to FP16 GGUF (format change only, no quantisation)"
docker run --rm -v "$(pwd)/quantisation:/models" ghcr.io/ggml-org/llama.cpp:full \
  --convert --outtype f16 --outfile /models/qwen-f16.gguf /models/qwen-fp16/

echo "==> Step 3: quantise FP16 to Q4_K_M (block-wise 4-bit with per-block scales)"
docker run --rm -v "$(pwd)/quantisation:/models" ghcr.io/ggml-org/llama.cpp:full \
  --quantize /models/qwen-f16.gguf /models/qwen-q4_k_m.gguf Q4_K_M

echo "==> Done. Sizes:"
ls -lh quantisation/*.gguf
