#!/bin/bash
# Deploy multi-GPU llama.cpp inference with layer-parallel compute
# Works with CUDA 12.4 (no vLLM 2.11.0 requirement)

set -e

echo "========================================================================="
echo "Multi-GPU llama.cpp Inference Deployment (CUDA 12.4 Compatible)"
echo "========================================================================="

# Check if already running
if pgrep -f "llama_cpp_multi_gpu_api.py" > /dev/null; then
    echo "⚠️  llama.cpp API already running. Stopping..."
    pkill -f "llama_cpp_multi_gpu_api.py" || true
    sleep 2
fi

# Ensure GGUF model exists
GGUF_PATH="/NVME/models/gguf/mistral-7b-instruct-v0.2.Q4_K_M.gguf"
if [ ! -f "$GGUF_PATH" ]; then
    echo "❌ GGUF model not found at $GGUF_PATH"
    echo "Run: python convert_to_gguf.py"
    exit 1
fi

echo "✅ GGUF model found: $GGUF_PATH ($(du -h "$GGUF_PATH" | cut -f1))"

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

# Set CUDA environment for compatibility
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_LAUNCH_BLOCKING=1

# GPU layer distribution config
export N_GPU_LAYERS=32      # All Mistral-7B layers across GPUs
export BATCH_SIZE=128
export CONTEXT_SIZE=2048

echo ""
echo "Configuration:"
echo "  Framework: llama.cpp (layer-parallel)"
echo "  Model: Mistral-7B-Instruct-v0.2"
echo "  Parallelism: True layer-level distribution"
echo "  CUDA: 12.4 compatible ✅"
echo "  GPU0: RTX 3060 (layers 0-15)"
echo "  GPU1: Quadro P6000 (layers 16-31)"
echo "  Port: 8000"
echo ""

# Check GPU status before starting
echo "GPU Status before launch:"
nvidia-smi --query-gpu=index,name,memory.free --format=csv,noheader,nounits

echo ""
echo "🚀 Starting llama.cpp multi-GPU API server..."
echo "This will take 15-30 seconds to load model and warm up..."
echo ""

# Start in background with output capture
python llama_cpp_multi_gpu_api.py > /tmp/llama_cpp_api.log 2>&1 &
SERVER_PID=$!

# Wait for server to be ready
echo "Waiting for server to be ready..."
max_wait=60
elapsed=0

while [ $elapsed -lt $max_wait ]; do
    if curl -s http://localhost:8000/health > /dev/null 2>&1; then
        echo "✅ Server is ready!"
        break
    fi
    elapsed=$((elapsed + 2))
    sleep 2
done

if [ $elapsed -ge $max_wait ]; then
    echo "⚠️  Server startup timeout after ${max_wait}s"
    echo "Last 30 lines of log:"
    tail -30 /tmp/llama_cpp_api.log
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi

echo ""
echo "========================================================================="
echo "✅ Multi-GPU llama.cpp API RUNNING"
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
echo '      "messages": [{"role": "user", "content": "Hello! What is 2+2?"}],
echo '      "max_tokens": 50
echo '    }'"'"
echo ""
echo "Monitor GPU utilization (both should be active):"
echo "  watch -n 1 nvidia-smi"
echo ""
echo "Stop server:"
echo "  pkill -f llama_cpp_multi_gpu_api.py"
echo ""
echo "Log file: /tmp/llama_cpp_api.log"
echo "========================================================================="

# Keep process in foreground by waiting on it
wait $SERVER_PID
