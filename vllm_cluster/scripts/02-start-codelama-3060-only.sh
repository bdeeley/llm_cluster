#!/bin/bash
# Load CodeLlama-34B across BOTH RTX 3060s (maxpower GPU0 + theplague GPU0)
# Hide Quadro P6000 completely

set -e

cd /home/bdeeley/test/vllm_cluster

# Activate venv
source /home/bdeeley/test/.venv/bin/activate

# Hide the Quadro P6000 - ONLY use RTX 3060 (GPU 0)
export CUDA_VISIBLE_DEVICES=0
export HF_HOME=/NVME/huggingface
export TRANSFORMERS_CACHE=/NVME/huggingface/models

echo "=========================================="
echo "🚀 vLLM Server - BOTH 3060s Only"
echo "=========================================="
echo "GPU 0: maxpower RTX 3060 (12GB)"
echo "Model: CodeLlama-34b-Instruct-hf (~20GB)"
echo "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
echo ""

# Download model if needed
python3 << 'EOF'
from transformers import AutoTokenizer, AutoModelForCausalLM
import torch

print("Checking model availability...")
model_name = "codellama/CodeLlama-34b-Instruct-hf"

try:
    tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
    print(f"✓ Tokenizer cached")
except:
    print(f"Downloading tokenizer...")
    tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)

print(f"✓ Model ready for loading")
EOF

echo ""
echo "Starting vLLM server..."
echo "  /v1/chat/completions endpoint on port 8000"
echo ""

# Start vLLM with proper settings
python3 -m vllm.entrypoints.openai.api_server \
  --model codellama/CodeLlama-34b-Instruct-hf \
  --dtype float16 \
  --gpu-memory-utilization 0.95 \
  --port 8000 \
  --host 0.0.0.0 \
  --tensor-parallel-size 1 \
  --max-model-len 4096 \
  --trust-remote-code
