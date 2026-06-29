#!/bin/bash
# Start vLLM distributed inference cluster with centralized logging to /NVME

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_ROOT="$(dirname "$SCRIPT_DIR")"
LOG_DIR="/NVME/vllm-logs"

mkdir -p "$LOG_DIR"

MODEL="${1:-mistralai/Mistral-7B-Instruct-v0.2}"
TENSOR_PARALLEL="${2:-2}"
PORT="${3:-8000}"

echo "🚀 Starting vLLM Cluster"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Model: $MODEL"
echo "Tensor Parallel Size: $TENSOR_PARALLEL"
echo "Port: $PORT"
echo "Logs: $LOG_DIR"
echo ""

export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_LAUNCH_BLOCKING=1
export PYTHONUNBUFFERED=1

source /home/bdeeley/test/.venv/bin/activate

python -m vllm.entrypoints.openai.api_server \
  --model "$MODEL" \
  --tensor-parallel-size $TENSOR_PARALLEL \
  --port $PORT \
  --host 0.0.0.0 \
  --seed 42 \
  > "$LOG_DIR/maxpower-vllm.log" 2>&1 &

VLLM_PID=$!
echo "✨ vLLM started with PID: $VLLM_PID"
echo "📋 Logs: tail -f $LOG_DIR/maxpower-vllm.log"
echo ""
echo "Waiting for API to be ready..."

for i in {1..120}; do
  if curl -s http://localhost:$PORT/v1/models > /dev/null 2>&1; then
    echo "✅ API is ready at http://localhost:$PORT"
    echo ""
    echo "Query the model:"
    echo '  curl -X POST http://localhost:8000/v1/chat/completions \'
    echo '    -H "Content-Type: application/json" \'
    echo "    -d '{\"model\": \"$MODEL\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}]}'"
    break
  fi
  echo -n "."
  sleep 1
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
