#!/bin/bash
# Start vLLM server with Ray tensor parallelism

VENV="/home/bdeeley/test/.venv"
PATH="$VENV/bin:$PATH"

TENSOR_PARALLEL=${1:-2}  # Default 2 GPUs
MODEL=${2:-meta-llama/Llama-2-7B-hf}
PORT=${3:-8000}

echo "=== Starting vLLM Server ==="
echo "Model: $MODEL"
echo "Tensor Parallel Size: $TENSOR_PARALLEL"
echo "Port: $PORT"
echo ""

python -m vllm.entrypoints.openai.api_server \
  --model "$MODEL" \
  --tensor-parallel-size $TENSOR_PARALLEL \
  --pipeline-parallel-size 1 \
  --gpu-memory-utilization 0.9 \
  --port $PORT \
  --host 0.0.0.0 \
  --seed 42 \
  --trust-remote-code

echo ""
echo "vLLM ready at http://localhost:$PORT"
