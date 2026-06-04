#!/bin/bash
set -e

# Quick test of the RunnerIdle fix

source /home/bdeeley/test/node-config.env
source /home/bdeeley/exo/.venv/bin/activate

echo "=========================================="
echo "Testing Runner Initialization Fix"
echo "=========================================="

# Kill any existing processes
pkill -f "exo.master" || true
pkill -f "exo.worker" || true
sleep 2

# Clean cache
rm -rf ~/.cache/exo-cluster || true

echo "[1/3] Starting master node..."
cd /home/bdeeley/exo
python -m exo.master.main --port $MASTER_API_PORT \
    --master-node --libp2p-port $MASTER_LIBP2P_PORT \
    > /tmp/exo-master.log 2>&1 &
MASTER_PID=$!
echo "  Master PID: $MASTER_PID"

echo "[2/3] Starting worker node..."
python -m exo.worker.main --port $WORKER_API_PORT \
    --libp2p-port $WORKER_LIBP2P_PORT \
    > /tmp/exo-worker.log 2>&1 &
WORKER_PID=$!
echo "  Worker PID: $WORKER_PID"

sleep 5

echo "[3/3] Testing model placement..."
# Try to place a simple model
RESPONSE=$(curl -s -X POST "http://localhost:$MASTER_API_PORT/place_instance" \
  -H "Content-Type: application/json" \
  -d '{"model_id":"mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit"}')

echo "Placement response:"
echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"

# Monitor runner status for 30 seconds
echo ""
echo "Monitoring runner status for 30 seconds..."
for i in {1..6}; do
    sleep 5
    STATUS=$(curl -s "http://localhost:$MASTER_API_PORT/status" | jq '.state.runners' 2>/dev/null | head -20)
    echo "[$((i*5))s] Runners status:"
    echo "$STATUS" | head -10
    echo ""
done

# Cleanup
kill $MASTER_PID $WORKER_PID 2>/dev/null || true
wait 2>/dev/null || true

echo "=========================================="
echo "Test complete. Check logs:"
echo "  Master: tail -50 /tmp/exo-master.log | grep -E 'RunnerIdle|ConnectToGroup|LoadModel|StartWarmup'"
echo "  Worker: tail -50 /tmp/exo-worker.log | grep -E 'RunnerIdle|ConnectToGroup|LoadModel|StartWarmup|plan'"
echo "=========================================="
