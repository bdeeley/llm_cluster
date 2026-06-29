#!/bin/bash
# Deploy DeepSpeed Tensor-Parallel Multi-GPU Inference
# Works with CUDA 12.4 + PyTorch 2.6.0

set -e

echo "========================================================================="
echo "DeepSpeed Tensor-Parallel Multi-GPU Inference (CUDA 12.4 Compatible)"
echo "========================================================================="

# Check if already running
if pgrep -f "deepspeed_tensor_parallel_api.py" > /dev/null; then
    echo "⚠️  DeepSpeed API already running. Stopping..."
    pkill -f "deepspeed_tensor_parallel_api.py" || true
    sleep 3
fi

# Setup environment
SCRIPT_DIR="$(dirname "$0")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_PATH="/home/bdeeley/test/.venv"

if [ ! -d "$VENV_PATH" ]; then
    echo "❌ Virtual environment not found at $VENV_PATH"
    exit 1
fi

source "$VENV_PATH/bin/activate"
cd "$PROJECT_DIR"

# Set CUDA environment for CUDA 12.4 compatibility
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_LAUNCH_BLOCKING=1
export CUDA_VISIBLE_DEVICES=0,1

# DeepSpeed-specific tuning
export DS_SKIP_CUDA_CHECK=1
export DS_SKIP_NVTX=1

echo ""
echo "Configuration:"
echo "  Framework: DeepSpeed"
echo "  Model: Mistral-7B-Instruct-v0.2"
echo "  Parallelism: Tensor-parallel (matrix ops split across GPUs)"
echo "  CUDA: 12.4 compatible ✅"
echo "  PyTorch: 2.6.0+cu124 ✅"
echo "  GPU0: RTX 3060 (partial attention/FFN)"
echo "  GPU1: Quadro P6000 (partial attention/FFN)"
echo "  Port: 8000"
echo ""

# Check GPU status before starting
echo "GPU Status before launch:"
nvidia-smi --query-gpu=index,name,memory.free --format=csv,noheader,nounits

echo ""
echo "🚀 Starting DeepSpeed Tensor-Parallel API server..."
echo "This will take 20-40 seconds to initialize tensor parallelism..."
echo ""

# Start in background with output capture
python deepspeed_tensor_parallel_api.py > /tmp/deepspeed_api.log 2>&1 &
SERVER_PID=$!

# Wait for server to be ready
echo "Waiting for server to be ready..."
max_wait=90
elapsed=0

while [ $elapsed -lt $max_wait ]; do
    if curl -s http://localhost:8000/health > /dev/null 2>&1; then
        echo "✅ Server is ready!"
        break
    fi
    elapsed=$((elapsed + 3))
    echo "  Waiting... ($elapsed/${max_wait}s)"
    sleep 3
done

if [ $elapsed -ge $max_wait ]; then
    echo "⚠️  Server startup timeout after ${max_wait}s"
    echo "Last 50 lines of log:"
    tail -50 /tmp/deepspeed_api.log
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

echo ""
echo "========================================================================="
echo "✅ DeepSpeed Tensor-Parallel API RUNNING"
echo "========================================================================="
echo ""
echo "API Endpoints:"
echo "  • Health Check:    curl http://localhost:8000/health"
echo "  • List Models:     curl http://localhost:8000/v1/models"
echo "  • GPU Status:      curl http://localhost:8000/v1/cluster/status"
echo "  • Chat API:        POST http://localhost:8000/v1/chat/completions"
echo ""
echo "Test query:"
echo '  curl -X POST http://localhost:8000/v1/chat/completions \'
echo '    -H "Content-Type: application/json" \'
echo '    -d '"'"'{
echo '      "model": "mistralai/Mistral-7B-Instruct-v0.2",
echo '      "messages": [{"role": "user", "content": "What is quantum computing?"}],
echo '      "max_tokens": 100
echo '    }'"'"
echo ""
echo "IMPORTANT: Monitor GPU utilization during inference"
echo "BOTH GPUs should show ACTIVE utilization (tensor parallelism in action)"
echo "  watch -n 0.5 'nvidia-smi --query-gpu=index,utilization.gpu --format=csv,noheader'"
echo ""
echo "Stop server:"
echo "  pkill -f deepspeed_tensor_parallel_api.py"
echo ""
echo "Log file: /tmp/deepspeed_api.log"
echo "========================================================================="

# Keep process in foreground by waiting on it
wait $SERVER_PID
