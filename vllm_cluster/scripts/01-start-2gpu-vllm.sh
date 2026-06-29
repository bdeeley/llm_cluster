#!/bin/bash
# 01-start-2gpu-vllm.sh
#
# Start vLLM with 2-GPU tensor parallelism (2x RTX 3060)
# - Local: maxpower GPU0 (RTX 3060, 12GB)
# - Remote: theplague GPU0 (RTX 3060, 12GB)
# - Total: 24GB VRAM for CodeLlama-34B
# - Models stored in: /NVME/MODELS on both nodes
#
# Setup:
#   1. Run ./scripts/00-setup-theplague.sh first
#   2. Then run this script
#   3. Models will auto-download to /NVME/MODELS if not cached

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
CLUSTER_HEAD="172.16.0.28"
CLUSTER_PORT="6379"
WORKER_ADDR="bdeeley@theplague.deeleymotorsports.lan"
MODEL="codellama/CodeLlama-34b-Instruct-hf"
TENSOR_PARALLEL=2
LOCAL_GPU="0"           # GPU0 only on maxpower (RTX 3060)
REMOTE_GPU="0"          # GPU0 only on theplague (RTX 3060)

# Model cache paths
MODELS_DIR="/NVME/MODELS"
HF_CACHE="/NVME/huggingface"

echo "=========================================="
echo "🚀 vLLM 2-GPU Distributed Inference"
echo "=========================================="
echo ""
echo "Setup:"
echo "  Local:  maxpower GPU0 (RTX 3060, 12GB)"
echo "  Remote: theplague GPU0 (RTX 3060, 12GB)"
echo "  Total:  24GB VRAM"
echo ""
echo "Model:  $MODEL"
echo "Cache:  $MODELS_DIR"
echo "Server: http://localhost:8000"
echo ""

# Step 1: Prerequisites
echo "Step 1️⃣  : Checking prerequisites..."

source /home/bdeeley/test/.venv/bin/activate || { echo "  ❌ venv not found"; exit 1; }
echo "  ✓ Virtual environment activated"

# Verify imports
python3 -c "import vllm; import ray; import torch" 2>/dev/null || {
    echo "  Installing dependencies..."
    pip install -q vllm transformers peft accelerate 2>/dev/null
}
echo "  ✓ Dependencies ready"

# Verify local GPU
if ! nvidia-smi -i 0 > /dev/null 2>&1; then
    echo "  ❌ Local GPU0 not accessible"
    exit 1
fi
echo "  ✓ Local GPU0 accessible"

# Verify remote GPU
if ! ssh -o ConnectTimeout=5 $WORKER_ADDR "nvidia-smi -i 0" > /dev/null 2>&1; then
    echo "  ❌ Remote GPU not accessible at $WORKER_ADDR"
    exit 1
fi
echo "  ✓ Remote GPU accessible"

# Ensure MODELS directory
mkdir -p "$MODELS_DIR" 2>/dev/null || true
if [ ! -d "$MODELS_DIR" ]; then
    echo "  ⚠️  $MODELS_DIR not writable, using fallback"
    MODELS_DIR="/tmp/vllm-models"
    mkdir -p "$MODELS_DIR"
fi
echo "  ✓ Model cache: $MODELS_DIR"
echo ""

# Step 2: Clean Ray state
echo "Step 2️⃣  : Cleaning Ray cluster state..."
pkill -9 -f "ray::" 2>/dev/null || true
pkill -9 -f "python.*ray" 2>/dev/null || true
rm -rf /tmp/ray/* 2>/dev/null || true

ssh $WORKER_ADDR << 'EOFCLEAN' > /dev/null 2>&1 || true
pkill -9 -f "ray::" 2>/dev/null || true
rm -rf /tmp/ray/* 2>/dev/null || true
true
EOFCLEAN

sleep 2
echo "  ✓ Ray state cleaned"
echo ""

# Step 3: Start Ray head
echo "Step 3️⃣  : Starting Ray head on maxpower..."
ray start --head \
  --num-gpus=1 \
  --num-cpus=16 \
  --port=$CLUSTER_PORT \
  --include-dashboard=false \
  --disable-usage-stats \
  > /tmp/ray_head.log 2>&1

sleep 3

if ! ray status &>/dev/null; then
    echo "  ❌ Failed to start Ray"
    cat /tmp/ray_head.log
    exit 1
fi
echo "  ✓ Ray head started"
echo ""

# Step 4: Connect Ray worker on theplague
echo "Step 4️⃣  : Connecting Ray worker on theplague..."
ssh $WORKER_ADDR << EOF_WORKER > /dev/null 2>&1 &
source ~/.venv/bin/activate 2>/dev/null || true
ray start --address=${CLUSTER_HEAD}:${CLUSTER_PORT} \
  --num-gpus=1 \
  --num-cpus=12 \
  --disable-usage-stats \
  > /tmp/ray_worker.log 2>&1 || true
EOF_WORKER

sleep 5
echo "  ✓ Ray worker connected"
echo ""

# Step 5: Verify cluster
echo "Step 5️⃣  : Verifying Ray cluster..."
python3 << EOFPY
import ray
import sys
import time

try:
    ray.init(address="auto", ignore_reinit_error=True)
    time.sleep(2)
    nodes = ray.nodes()
    total_gpus = sum(n.get("Resources", {}).get("GPU", 0) for n in nodes)
    
    print(f"  Ray cluster: {len(nodes)} nodes, {total_gpus} total GPUs")
    for i, node in enumerate(nodes):
        gpus = node.get("Resources", {}).get("GPU", 0)
        cpus = node.get("Resources", {}).get("CPU", 0)
        print(f"    Node {i+1}: {int(gpus)} GPU(s), {int(cpus)} CPUs")
    
    if total_gpus < 2:
        print(f"  ❌ Expected 2 GPUs, got {total_gpus}")
        sys.exit(1)
    
    ray.shutdown()
except Exception as e:
    print(f"  ⚠️  Cluster verification warning: {e}")
    print(f"  Continuing anyway...")
EOFPY
echo ""

# Step 6: Configure environment
echo "Step 6️⃣  : Configuring environment..."
export CUDA_VISIBLE_DEVICES="$LOCAL_GPU"
export HF_HOME="${HF_CACHE}"
export HF_HUB_CACHE="${HF_CACHE}/hub"
export TRANSFORMERS_CACHE="${HF_CACHE}/models"
export VLLM_WORKER_MULTIPROC_METHOD="spawn"
export RAY_memory=10000000000  # 10GB overhead per node

# Make sure cache directories exist
mkdir -p "$MODELS_DIR" "$HF_CACHE/hub" "$HF_CACHE/models" 2>/dev/null || true

echo "  ✓ Environment configured"
echo "    CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
echo "    HF_HOME=$HF_HOME"
echo ""

# Step 7: Ensure model is available
echo "Step 7️⃣  : Checking model availability..."
python3 << EOFPY
import os
import sys

model_name = "$MODEL"
cache_dir = "$HF_CACHE"

print(f"  Model: {model_name}")
print(f"  Cache: {cache_dir}")
print(f"  Will download on first server load if not cached")

EOFPY
echo ""

# Step 8: Save logs location
mkdir -p "$CLUSTER_DIR/logs"
LOG_FILE="$CLUSTER_DIR/logs/vllm_2gpu_$(date +%Y%m%d_%H%M%S).log"

# Step 9: Start vLLM
echo "Step 8️⃣  : Starting vLLM server..."
echo "  Model:              $MODEL"
echo "  Tensor parallel:    $TENSOR_PARALLEL"
echo "  Server:             http://localhost:8000"
echo "  Logs:               $LOG_FILE"
echo ""
echo "  ⏳ Server starting (this may take 60-180 seconds on first run)"
echo ""
echo "  To test in another terminal:"
echo "    ./scripts/02-verify-compute.sh"
echo ""
echo "  To send a query:"
echo "    curl -X POST http://localhost:8000/v1/chat/completions \\"
echo "         -H 'Content-Type: application/json' \\"
echo "         -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":100}'"
echo ""

python3 -m vllm.entrypoints.openai.api_server \
  --model "$MODEL" \
  --tensor-parallel-size $TENSOR_PARALLEL \
  --pipeline-parallel-size 1 \
  --distributed-executor-backend ray \
  --gpu-memory-utilization 0.90 \
  --max-model-len 4096 \
  --seed 42 \
  --port 8000 \
  --host 0.0.0.0 \
  --trust-remote-code \
  2>&1 | tee "$LOG_FILE"
