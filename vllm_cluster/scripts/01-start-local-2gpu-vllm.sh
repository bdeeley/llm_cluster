#!/bin/bash
# 01-start-local-2gpu-vllm.sh
#
# Start vLLM with 2-GPU tensor parallelism (local only)
# Uses maxpower GPU0 (RTX 3060, 12GB) + GPU1 (Quadro P6000, 24GB)
# Total: 36GB VRAM for larger models
#
# Note: Uses local tensor parallelism only (no remote distribution)
# This avoids CUDA version conflicts across nodes

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
MODEL="codellama/CodeLlama-34b-Instruct-hf"
TENSOR_PARALLEL=2
GPU_DEVICES="0,1"  # Both local GPUs

# Model cache paths
MODELS_DIR="/NVME/MODELS"
HF_CACHE="/NVME/huggingface"

echo "=========================================="
echo "🚀 vLLM Local 2-GPU Inference"
echo "=========================================="
echo ""
echo "Setup:"
echo "  GPU0: maxpower RTX 3060 (12GB)"
echo "  GPU1: maxpower Quadro P6000 (24GB)"
echo "  Total: 36GB VRAM"
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
python3 -c "import vllm; import torch" 2>/dev/null || {
    echo "  Installing dependencies..."
    pip install -q vllm transformers peft accelerate 2>/dev/null
}
echo "  ✓ Dependencies ready"

# Verify GPUs
NGPUS=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | head -1)
if [ "$NGPUS" -lt 2 ]; then
    echo "  ❌ Expected 2 GPUs, found $NGPUS"
    exit 1
fi
echo "  ✓ Both GPUs accessible ($NGPUS GPUs found)"
echo ""

# Step 2: Ensure MODELS directory
mkdir -p "$MODELS_DIR" 2>/dev/null || true
if [ ! -d "$MODELS_DIR" ]; then
    echo "  ⚠️  $MODELS_DIR not writable, using fallback"
    MODELS_DIR="/tmp/vllm-models"
    mkdir -p "$MODELS_DIR"
fi
echo "  ✓ Model cache: $MODELS_DIR"
echo ""

# Step 3: Configure environment
echo "Step 2️⃣  : Configuring environment..."
export CUDA_VISIBLE_DEVICES="$GPU_DEVICES"
export HF_HOME="${HF_CACHE}"
export HF_HUB_CACHE="${HF_CACHE}/hub"
export TRANSFORMERS_CACHE="${HF_CACHE}/models"
export VLLM_WORKER_MULTIPROC_METHOD="spawn"

# Make sure cache directories exist
mkdir -p "$MODELS_DIR" "$HF_CACHE/hub" "$HF_CACHE/models" 2>/dev/null || true

echo "  ✓ Environment configured"
echo "    CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
echo "    HF_HOME=$HF_HOME"
echo ""

# Step 4: Save logs location
mkdir -p "$CLUSTER_DIR/logs"
LOG_FILE="$CLUSTER_DIR/logs/vllm_local_2gpu_$(date +%Y%m%d_%H%M%S).log"

# Step 5: Start vLLM
echo "Step 3️⃣  : Starting vLLM server..."
echo "  Model:              $MODEL"
echo "  Tensor parallel:    $TENSOR_PARALLEL (local GPUs)"
echo "  Server:             http://localhost:8000"
echo "  Logs:               $LOG_FILE"
echo ""
echo "  ⏳ Server starting (this may take 30-120 seconds on first run)"
echo ""
echo "  To test in another terminal:"
echo "    curl -X POST http://localhost:8000/v1/chat/completions \\"
echo "         -H 'Content-Type: application/json' \\"
echo "         -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":100}'"
echo ""

# Start vLLM with local tensor parallelism only
python3 -m vllm.entrypoints.openai.api_server \
  --model "$MODEL" \
  --tensor-parallel-size $TENSOR_PARALLEL \
  --pipeline-parallel-size 1 \
  --gpu-memory-utilization 0.90 \
  --max-model-len 4096 \
  --seed 42 \
  --port 8000 \
  --host 0.0.0.0 \
  --trust-remote-code \
  2>&1 | tee "$LOG_FILE"
