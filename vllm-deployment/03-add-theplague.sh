#!/bin/bash
# Join theplague to Ray cluster on maxpower

VENV="/home/bdeeley/test/.venv"
PATH="$VENV/bin:$PATH"

MAXPOWER_IP="172.16.0.28"
RAY_PORT=6379

echo "=== Connecting theplague to Ray cluster ==="
echo "Master: $MAXPOWER_IP:$RAY_PORT"

ssh bdeeley@$MAXPOWER_IP "
  echo 'Testing connectivity to theplague...'
  ping -c 1 172.16.0.29
" 2>&1 | head -5

echo ""
ssh bdeeley@172.16.0.29 "
  pip install -q ray torch 2>/dev/null
  ray start --address=$MAXPOWER_IP:$RAY_PORT 2>&1 | tail -10
"

sleep 3
echo ""
echo "=== Ray Cluster Status ==="
ray status
