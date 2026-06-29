#!/bin/bash
# vLLM Multi-Node Cluster Deployment
# Maxpower + Theplague (3 GPUs total, 60GB VRAM)

set -e

VENV="/home/bdeeley/test/.venv"
PATH="$VENV/bin:$PATH"

MAXPOWER_IP="172.16.0.28"
THEPLAGUE_IP="172.16.0.29"
RAY_PORT=6379
VLLM_PORT=8000

echo "=== Using venv: $VENV ==="
echo "=== Dependencies already installed ==="

echo "=== Starting Ray Head on maxpower ==="
ray start --head --port=$RAY_PORT --object-store-memory 50000000000 2>/dev/null || ray stop && ray start --head --port=$RAY_PORT --object-store-memory 50000000000

sleep 3

echo "=== Ray Status ==="
ray status

echo ""
echo "=== To start vLLM with tensor parallelism ==="
echo ""
echo "Single-node (2 GPUs):"
echo "  python -m vllm.entrypoints.openai.api_server --model meta-llama/Llama-2-7B-hf --tensor-parallel-size 2 --port $VLLM_PORT"
echo ""
echo "To add theplague worker:"
echo "  ssh bdeeley@$THEPLAGUE_IP 'ray start --address=$MAXPOWER_IP:$RAY_PORT'"
echo ""
echo "For 3-GPU tensor parallel:"
echo "  python -m vllm.entrypoints.openai.api_server --model meta-llama/Llama-2-7B-hf --tensor-parallel-size 3 --port $VLLM_PORT"
