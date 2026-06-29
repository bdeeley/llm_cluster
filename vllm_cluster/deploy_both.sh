#!/bin/bash
# Deploy and start CodeLlama-34B cluster on both maxpower and theplague

set -e

CLUSTER_DIR="/home/bdeeley/test/vllm_cluster"
THEPLAGUE_HOST="172.16.0.62"
THEPLAGUE_USER="bdeeley"

echo "======================================================================"
echo "🚀 Deploying Active-Active CodeLlama-34B Cluster"
echo "======================================================================"

# 1. Start on maxpower (this host)
echo ""
echo "1️⃣  Starting inference server on maxpower..."
cd "$CLUSTER_DIR"
source /home/bdeeley/test/.venv/bin/activate
nohup python3 inference_server_unified.py > /tmp/maxpower_inference.log 2>&1 &
MAXPOWER_PID=$!
echo "✓ maxpower started (PID: $MAXPOWER_PID)"
sleep 2

# 2. Deploy to theplague and start
echo ""
echo "2️⃣  Deploying to theplague ($THEPLAGUE_HOST)..."
ssh -o ConnectTimeout=5 "$THEPLAGUE_USER@$THEPLAGUE_HOST" bash -s << 'REMOTE_SCRIPT'
#!/bin/bash
set -e

CLUSTER_DIR="/home/bdeeley/test/vllm_cluster"

echo "Setting up environment on theplague..."
export HF_HOME=/NVME/huggingface
export CUDA_VISIBLE_DEVICES=0
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_LAUNCH_BLOCKING=1

# Ensure venv exists
if [ ! -d "/home/bdeeley/test/.venv" ]; then
    echo "Creating venv on theplague..."
    cd /home/bdeeley/test
    python3 -m venv .venv
    source .venv/bin/activate
    pip install --upgrade pip
    cd "$CLUSTER_DIR"
    pip install -q -r requirements.txt
fi

source /home/bdeeley/test/.venv/bin/activate

echo "Starting inference server on theplague..."
cd "$CLUSTER_DIR"
nohup python3 inference_server_unified.py > /tmp/theplague_inference.log 2>&1 &
echo "✓ theplague started"

echo "Checking GPU memory on theplague..."
nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader,nounits | head -2
REMOTE_SCRIPT

echo "✓ theplague deployed and started"

# 3. Verify both are running
echo ""
echo "======================================================================"
echo "✅ Cluster Status"
echo "======================================================================"
sleep 5

echo ""
echo "maxpower GPU Memory:"
nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader,nounits

echo ""
echo "Testing maxpower health..."
curl -s http://localhost:8000/health | python3 -m json.tool | head -8

echo ""
echo "Testing theplague health..."
ssh "$THEPLAGUE_USER@$THEPLAGUE_HOST" curl -s http://localhost:8000/health | python3 -m json.tool | head -8

echo ""
echo "======================================================================"
echo "✅ BOTH NODES ACTIVE"
echo "======================================================================"
echo ""
echo "API Endpoints:"
echo "  maxpower: http://localhost:8000/v1/chat/completions"
echo "  theplague: http://$THEPLAGUE_HOST:8000/v1/chat/completions"
echo ""
echo "Logs:"
echo "  maxpower: tail -f /tmp/maxpower_inference.log"
echo "  theplague: ssh $THEPLAGUE_USER@$THEPLAGUE_HOST tail -f /tmp/theplague_inference.log"
echo ""
