#!/bin/bash
# Test vLLM inference and monitor VRAM

VENV="/home/bdeeley/test/.venv"
PATH="$VENV/bin:$PATH"

VLLM_PORT=${1:-8000}
VLLM_HOST="127.0.0.1"
MODEL="meta-llama/Llama-2-7B-hf"

echo "=== Pre-Test VRAM ==="
nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader

echo ""
echo "=== Testing vLLM inference ==="
echo "Endpoint: http://$VLLM_HOST:$VLLM_PORT/v1/chat/completions"
echo ""

# Test with small payload first
echo "Sending inference request..."
RESPONSE=$(curl -s -X POST "http://$VLLM_HOST:$VLLM_PORT/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Hello, how are you?\"}],
    \"max_tokens\": 20,
    \"temperature\": 0.7
  }" -w "\n")

echo "Response:"
echo "$RESPONSE" | jq '.' 2>/dev/null || echo "$RESPONSE"

echo ""
echo "=== Post-Test VRAM (should show usage) ==="
nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader

echo ""
echo "=== Live GPU Monitor (Ctrl+C to stop) ==="
watch -n 1 'nvidia-smi --query-gpu=index,name,memory.used,memory.total,utilization.gpu --format=csv,noheader'
