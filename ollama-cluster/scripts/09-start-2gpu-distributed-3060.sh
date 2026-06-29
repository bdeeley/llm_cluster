#!/bin/bash
# 09-start-2gpu-distributed-3060.sh
# 
# 2-GPU Distributed Inference (2x RTX 3060)
# Local: maxpower GPU0 (RTX 3060, 12GB)
# Remote: theplague GPU0 (RTX 3060, 12GB)
# Total: 24GB VRAM, both GPUs computing in parallel
#
# Model: CodeLlama-34B-4bit (20GB) with tensor-parallel-size=2
# Expected: ~2x throughput vs single GPU

set -e

# Configuration
CLUSTER_HEAD="172.16.0.28"
CLUSTER_PORT="6379"
WORKER_ADDR="bdeeley@172.16.0.29"
MODEL="codellama/CodeLlama-34b-Instruct-hf"  # 80 attention heads → divisible by 2
TENSOR_PARALLEL=2
LOCAL_GPUS="0"          # Only GPU0 on maxpower (3060)
REMOTE_GPUS="0"         # Only GPU0 on theplague (3060)

echo "=========================================="
echo "🚀 2-GPU Distributed Inference (2x RTX 3060)"
echo "=========================================="
echo ""
echo "Local:  maxpower GPU0 (RTX 3060, 12GB)"
echo "Remote: theplague GPU0 (RTX 3060, 12GB)"
echo "Total:  24GB VRAM"
echo ""
echo "Model:  $MODEL (4-bit, ~20GB)"
echo "Parallel: tensor-parallel-size=$TENSOR_PARALLEL"
echo ""

# Step 1: Check prerequisites
echo "Step 1️⃣  : Checking prerequisites..."

# Check Ray isn't running
if pgrep -f "ray::" > /dev/null; then
    echo "  ⚠️  Ray already running, cleaning up..."
    pkill -9 -f "ray::" 2>/dev/null || true
    rm -rf /tmp/ray/* 2>/dev/null || true
    sleep 2
fi

# Activate venv
if [ ! -f "/home/bdeeley/test/.venv/bin/activate" ]; then
    echo "  ❌ Virtual environment not found"
    exit 1
fi
source /home/bdeeley/test/.venv/bin/activate
echo "  ✓ Virtual environment activated"

# Verify vLLM and dependencies
if ! python -c "import vllm; print(f'vLLM version: {vllm.__version__}')" 2>/dev/null; then
    echo "  ⚠️  vLLM not installed, installing..."
    pip install -q vllm[all] 2>/dev/null
fi
echo "  ✓ vLLM verified"

# Check GPU access
echo "  Checking local GPU..."
if ! nvidia-smi --query-gpu=index --format=csv,noheader | head -1 > /dev/null; then
    echo "  ❌ Local CUDA not accessible"
    exit 1
fi
echo "  ✓ Local GPU accessible"

# Check remote access
echo "  Checking remote GPU..."
if ! ssh -o ConnectTimeout=5 $WORKER_ADDR "nvidia-smi" > /dev/null 2>&1; then
    echo "  ❌ Cannot SSH to theplague at $WORKER_ADDR"
    exit 1
fi
echo "  ✓ Remote GPU accessible"
echo ""

# Step 2: Clean Ray state locally and remotely
echo "Step 2️⃣  : Cleaning Ray state..."
pkill -9 -f "ray::" 2>/dev/null || true
rm -rf /tmp/ray/* 2>/dev/null || true

ssh $WORKER_ADDR << 'EOF_REMOTE_CLEANUP' > /dev/null 2>&1 || true
pkill -9 -f "ray::" 2>/dev/null || true
rm -rf /tmp/ray/* 2>/dev/null || true
true
EOF_REMOTE_CLEANUP

sleep 2
echo "  ✓ Ray state cleaned"
echo ""

# Step 3: Start Ray head (maxpower)
echo "Step 3️⃣  : Starting Ray head on maxpower (1 GPU)..."
ray start --head \
  --num-gpus=1 \
  --num-cpus=16 \
  --port=$CLUSTER_PORT \
  --include-dashboard=false \
  --disable-usage-stats \
  > /tmp/ray_head.log 2>&1

sleep 3

if ! ray status &>/dev/null; then
    echo "  ❌ Failed to start Ray head"
    cat /tmp/ray_head.log
    exit 1
fi
echo "  ✓ Ray head started"
echo ""

# Step 4: Connect Ray worker (theplague)
echo "Step 4️⃣  : Connecting Ray worker on theplague (1 GPU)..."
ssh $WORKER_ADDR << EOF_WORKER_START > /tmp/ray_worker.log 2>&1 &
source ~/.venv/bin/activate
ray start --address=${CLUSTER_HEAD}:${CLUSTER_PORT} \
  --num-gpus=1 \
  --num-cpus=12 \
  --disable-usage-stats \
  > /tmp/ray_worker_local.log 2>&1
EOF_WORKER_START

sleep 5
echo "  ✓ Ray worker connected"
echo ""

# Step 5: Verify cluster
echo "Step 5️⃣  : Verifying Ray cluster (2 GPUs total)..."
python3 << 'EOFPY'
import ray
import time

ray.init(address="auto", ignore_reinit_error=True)
time.sleep(2)

nodes = ray.nodes()
total_gpus = 0

print(f"  Ray cluster: {len(nodes)} nodes")
for i, node in enumerate(nodes):
    resources = node.get("Resources", {})
    gpus = resources.get("GPU", 0)
    cpus = resources.get("CPU", 0)
    total_gpus += gpus
    print(f"    Node {i+1}: {gpus} GPU(s), {cpus} CPUs")

if total_gpus < 2:
    print(f"  ❌ Expected 2 GPUs total, got {total_gpus}")
    exit(1)

print(f"  ✓ Cluster ready: {total_gpus} total GPUs")
ray.shutdown()
EOFPY
echo ""

# Step 6: Verify model fits
echo "Step 6️⃣  : Checking model size vs VRAM..."
python3 << 'EOFPY'
# CodeLlama-34B 4-bit: ~20GB
# 24GB available = sufficient
print("  Model: CodeLlama-34B-Instruct (4-bit)")
print("  Estimated size: ~20 GB")
print("  Available VRAM: 24 GB (12GB + 12GB)")
print("  ✓ Fits with margin")
EOFPY
echo ""

# Step 7: Set environment variables for vLLM
echo "Step 7️⃣  : Configuring environment..."
export CUDA_VISIBLE_DEVICES="0"              # Only GPU0 on maxpower
export HF_HOME="/NVME/huggingface"
export HF_HUB_CACHE="/NVME/huggingface/hub"
export TRANSFORMERS_CACHE="/NVME/huggingface/models"
export VLLM_WORKER_MULTIPROC_METHOD="spawn"  # Safer for distributed
export RAY_memory=10000000000                 # 10GB per node for overhead
echo "  ✓ Environment configured"
echo ""

# Step 8: Download model (if not cached)
echo "Step 8️⃣  : Ensuring model is downloaded..."
python3 << 'EOFPY' || true
from transformers import AutoTokenizer
print("  Downloading tokenizer...")
AutoTokenizer.from_pretrained("codellama/CodeLlama-34b-Instruct-hf", cache_dir="/NVME/huggingface")
print("  ✓ Tokenizer ready (model will download on first serve)")
EOFPY
echo ""

# Step 9: Start vLLM with tensor parallelism
echo "Step 9️⃣  : Starting vLLM server..."
echo "  Model:              $MODEL"
echo "  Tensor parallel:    $TENSOR_PARALLEL"
echo "  API endpoint:       http://localhost:8000"
echo "  Expected ready in:  60-120 seconds (model download + load)"
echo ""
echo "  To test: curl -X POST http://localhost:8000/v1/chat/completions \\"
echo "           -H 'Content-Type: application/json' \\"
echo "           -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":100}'"
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
  --disable-log-requests \
  --trust-remote-code \
  2>&1 | tee /tmp/vllm_2gpu.log
