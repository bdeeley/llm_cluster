#!/bin/bash
# Full vLLM Cluster Deployment (Start-to-Finish)

set -e

VENV="/home/bdeeley/test/.venv"
export PATH="$VENV/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAXPOWER_IP="172.16.0.28"
THEPLAGUE_IP="172.16.0.29"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  vLLM Multi-Node Distributed Inference                    ║"
echo "║  Maxpower (2 GPUs) + Theplague (1 GPU) = 3-GPU cluster   ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Step 1: Setup Ray Head
echo "=== STEP 1: Setup Ray Head Node (maxpower) ==="
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  bash "$SCRIPT_DIR/01-setup-ray.sh"
fi

echo ""
echo "=== STEP 2: Add Theplague to Ray Cluster ==="
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  bash "$SCRIPT_DIR/03-add-theplague.sh"
fi

echo ""
echo "=== STEP 3: Start vLLM Server ==="
read -p "Enter tensor parallel size (default 2): " TP_SIZE
TP_SIZE=${TP_SIZE:-2}

read -p "Enter model name (default: meta-llama/Llama-2-7B-hf): " MODEL
MODEL=${MODEL:-meta-llama/Llama-2-7B-hf}

read -p "Enter vLLM port (default 8000): " PORT
PORT=${PORT:-8000}

echo ""
echo "Starting vLLM with:"
echo "  Tensor Parallel: $TP_SIZE"
echo "  Model: $MODEL"
echo "  Port: $PORT"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  bash "$SCRIPT_DIR/02-start-vllm.sh" "$TP_SIZE" "$MODEL" "$PORT" &
  VLLM_PID=$!
  
  sleep 30
  
  echo ""
  echo "=== STEP 4: Test Inference ==="
  bash "$SCRIPT_DIR/04-test-vllm.sh" "$PORT"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Deployment Complete!"
echo "vLLM API: http://localhost:$PORT"
echo "═══════════════════════════════════════════════════════════"
