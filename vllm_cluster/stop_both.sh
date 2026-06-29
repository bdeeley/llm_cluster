#!/bin/bash
# Stop CodeLlama-34B servers on both maxpower and theplague

THEPLAGUE_HOST="172.16.0.62"
THEPLAGUE_USER="bdeeley"

echo "Stopping inference servers..."

# Stop on maxpower
echo "Stopping maxpower..."
pkill -f "inference_server_unified.py" || true
sleep 1

# Stop on theplague
echo "Stopping theplague..."
ssh -o ConnectTimeout=5 "$THEPLAGUE_USER@$THEPLAGUE_HOST" pkill -f "inference_server_unified.py" || true

echo "✓ Both servers stopped"
