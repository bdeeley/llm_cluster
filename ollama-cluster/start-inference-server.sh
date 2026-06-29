#!/bin/bash
#
# Multi-GPU Inference Server Startup
# Loads Mistral-7B across maxpower GPUs (RTX 3060 + Quadro P6000)
# Logs to /NVME for centralized monitoring
# Query via: curl -X POST http://localhost:8000/v1/chat/completions -H "Content-Type: application/json" -d '...'
#

set -e

PROJECT_DIR="/home/bdeeley/test/ollama-cluster"
VENV_PATH="${PROJECT_DIR}/.venv"
LOG_DIR="/NVME/vllm-logs"
LOG_FILE="${LOG_DIR}/inference_server.log"

# Create log directory
mkdir -p "$LOG_DIR"

echo "=== Starting Multi-GPU Inference Server ==="
echo "Project: $PROJECT_DIR"
echo "Logs: $LOG_FILE"
echo

# Activate venv
source "${VENV_PATH}/bin/activate"

# Export CUDA settings for mixed GPU compatibility
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_LAUNCH_BLOCKING=1
export PYTHONUNBUFFERED=1

# Check GPU status
echo "GPU Status:"
nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader | sed 's/^/  /'
echo

# Start server
echo "Starting inference server..."
cd "$PROJECT_DIR"
python inference_server.py > "$LOG_FILE" 2>&1 &
SERVER_PID=$!
echo "✓ Server started (PID: $SERVER_PID)"
echo "✓ Logging to: $LOG_FILE"
echo

# Wait for startup
sleep 20

# Test API
echo "Testing API..."
if curl -s http://localhost:8000/health | grep -q "healthy"; then
    echo "✓ API is healthy and responding"
    echo
    echo "=== SERVER READY ==="
    echo "OpenAI-compatible API running on http://localhost:8000"
    echo "Documentation: http://localhost:8000/docs"
    echo "Models: curl http://localhost:8000/v1/models"
    echo
    echo "Example query from Cline:"
    echo '  curl -X POST http://localhost:8000/v1/chat/completions \'
    echo '    -H "Content-Type: application/json" \'
    echo '    -d '"'"'{"model": "mistral", "messages": [{"role": "user", "content": "Hello"}]}'"'"
    echo
    echo "Monitoring logs: tail -f $LOG_FILE"
    echo
else
    echo "✗ API health check failed. Check logs:"
    tail -20 "$LOG_FILE"
    exit 1
fi

# Keep process running
wait $SERVER_PID
