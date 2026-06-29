#!/bin/bash
# 06-start-vllm-cluster-distributed.sh
# Starts vLLM with distributed tensor parallelism across 3 GPUs
# 
# Setup:
#   maxpower: Ray head + vLLM with GPU0 and GPU1
#   theplague: Ray worker with GPU0
#   Result: All 3 GPUs participate in inference (1/3 compute each)

set -e

# Activate virtual environment
source /home/bdeeley/test/.venv/bin/activate

CLUSTER_HEAD="172.16.0.28"
CLUSTER_PORT="6379"
WORKER_ADDR="bdeeley@172.16.0.29"

echo "=========================================="
echo "vLLM Distributed Tensor Parallelism Setup"
echo "=========================================="
echo ""
echo "🎯 Goal: Make all 3 GPUs compute (not just Quadro)"
echo "📊 Method: vLLM tensor-parallel-size=3 with Ray backend"
echo "🌐 Network: 10Gbps between maxpower ↔ theplague"
echo ""

# Step 1: Verify Ray is clean
echo "Step 1️⃣ : Cleanup old Ray state..."
pkill -9 -f "ray::" 2>/dev/null || true
pkill -9 -f "python.*ray" 2>/dev/null || true
rm -rf /tmp/ray/* 2>/dev/null || true
sleep 2
echo "✓ Ray cleaned"
echo ""

# Step 2: Start Ray cluster head on maxpower
echo "Step 2️⃣ : Starting Ray head on maxpower..."
ray start --head \
  --num-gpus=2 \
  --num-cpus=16 \
  --port=$CLUSTER_PORT \
  --include-dashboard=false \
  --disable-usage-stats \
  > /tmp/ray_head.log 2>&1

sleep 3

# Verify Ray cluster started by checking ray status
if ! ray status &>/dev/null; then
    echo "❌ Failed to start Ray head"
    cat /tmp/ray_head.log
    exit 1
fi
echo "✓ Ray head started"
echo ""

# Step 3: Connect theplague worker to cluster
echo "Step 3️⃣ : Connecting theplague worker to Ray cluster..."
ssh $WORKER_ADDR << EOFREMOTE
source ~/.venv/bin/activate
pkill -9 -f "ray::" 2>/dev/null || true
rm -rf /tmp/ray/* 2>/dev/null || true
ray start --address=${CLUSTER_HEAD}:${CLUSTER_PORT} \
  --num-gpus=1 \
  --num-cpus=12 \
  --disable-usage-stats \
  > /tmp/ray_worker.log 2>&1 &
sleep 5
echo "✓ Ray worker started on theplague"
EOFREMOTE
echo ""

# Step 4: Verify cluster
echo "Step 4️⃣ : Verifying Ray cluster..."
python3 << 'EOFPY'
import ray
ray.init(address="auto", ignore_reinit_error=True)
nodes = ray.nodes()
print(f"✓ Ray cluster ready: {len(nodes)} nodes")
for i, node in enumerate(nodes):
    gpus = node.get("Resources", {}).get("GPU", 0)
    cpus = node.get("Resources", {}).get("CPU", 0)
    print(f"  Node {i+1}: {gpus} GPUs, {cpus} CPUs")
ray.shutdown()
EOFPY
echo ""

# Step 5: Start vLLM with tensor parallelism
echo "Step 5️⃣ : Starting vLLM with tensor-parallel-size=3..."
echo "  Model: CodeLlama-13B (4-bit)"
echo "  Parallelism: All 3 GPUs compute in parallel"
echo "  Context window: 4096 tokens"
echo "  API: http://localhost:8000"
echo ""

# Set environment for vLLM
export CUDA_VISIBLE_DEVICES="0,1"
export HF_HOME="/NVME/huggingface"
export HF_HUB_CACHE="/NVME/huggingface/hub"
export TRANSFORMERS_CACHE="/NVME/huggingface/models"

python3 -m vllm.entrypoints.openai.api_server \
  --model "codellama/CodeLlama-13b-hf" \
  --tensor-parallel-size 3 \
  --pipeline-parallel-size 1 \
  --distributed-executor-backend ray \
  --gpu-memory-utilization 0.90 \
  --max-model-len 4096 \
  --seed 42 \
  --port 8000 \
  --host 0.0.0.0 \
  --disable-log-requests \
  --trust-remote-code

