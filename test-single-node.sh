#!/bin/bash
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NODE_NAME="${1:-master}"
LOG_DIR="/tmp/exo-single-node-test"
mkdir -p "$LOG_DIR"

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  SINGLE NODE TEST - Troubleshooting Mode                       ║${NC}"
echo -e "${BLUE}║  Node: $NODE_NAME${NC}"
echo -e "${BLUE}║  Logs: $LOG_DIR${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Functions
stop_node() {
  local node=$1
  echo -e "${YELLOW}Stopping $node...${NC}"
  
  if [ "$node" = "master" ] || [ "$node" = "worker" ] || [ "$node" = "local" ]; then
    sudo systemctl stop exo.service exo-worker.service 2>/dev/null || true
  else
    ssh -o BatchMode=yes "bdeeley@$node" "sudo systemctl stop exo.service" 2>/dev/null || true
  fi
  
  sleep 2
}

cleanup_node() {
  local node=$1
  echo -e "${YELLOW}Clearing caches on $node...${NC}"
  
  if [ "$node" = "master" ] || [ "$node" = "worker" ] || [ "$node" = "local" ]; then
    rm -rf ~/.cache/exo* ~/.local/share/exo* 2>/dev/null || true
    sudo rm -rf /var/log/exo* 2>/dev/null || true
  else
    ssh -o BatchMode=yes "bdeeley@$node" "rm -rf ~/.cache/exo* ~/.local/share/exo*" 2>/dev/null || true
  fi
}

start_node() {
  local node=$1
  echo -e "${GREEN}Starting $node...${NC}"
  
  if [ "$node" = "master" ] || [ "$node" = "local-master" ]; then
    # Start master locally
    sudo systemctl daemon-reload
    sudo systemctl start exo.service
    echo -e "${GREEN}✓ Master service started${NC}"
    
  elif [ "$node" = "worker" ] || [ "$node" = "local-worker" ]; then
    # Start worker locally
    sudo systemctl daemon-reload
    sudo systemctl start exo-worker.service
    echo -e "${GREEN}✓ Worker service started${NC}"
    
  else
    # Start remote node
    echo "Starting $node via SSH..."
    ssh -o BatchMode=yes "bdeeley@$node" "sudo systemctl daemon-reload && sudo systemctl start exo.service" 2>&1 | tail -1 || true
    echo -e "${GREEN}✓ $node service started${NC}"
  fi
}

# Main test sequence
echo -e "${BLUE}STEP 1: Stopping all services${NC}"
stop_node "master"

echo ""
echo -e "${BLUE}STEP 2: Clearing caches${NC}"
cleanup_node "$NODE_NAME"

echo ""
echo -e "${BLUE}STEP 3: Starting single node ($NODE_NAME)${NC}"
start_node "$NODE_NAME"

echo ""
sleep 5

echo -e "${BLUE}STEP 4: Waiting for service to stabilize (15 seconds)${NC}"
for i in {1..15}; do
  echo -ne "\r  [$i/15] Waiting...    "
  sleep 1
done
echo ""

echo ""
echo -e "${BLUE}STEP 5: Checking service status${NC}"

if [ "$NODE_NAME" = "master" ] || [ "$NODE_NAME" = "local-master" ]; then
  if sudo systemctl is-active exo.service > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Master service is active${NC}"
  else
    echo -e "${RED}✗ Master service is NOT active${NC}"
    echo "Service status:"
    sudo systemctl status exo.service --no-pager || true
  fi
  
  # Try to connect to API
  echo ""
  echo -e "${YELLOW}Testing API connectivity...${NC}"
  if curl -s http://localhost:52415/node_id > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Master API is responding${NC}"
    echo "  Node ID: $(curl -s http://localhost:52415/node_id | jq -r '.node_id' 2>/dev/null || echo 'Unknown')"
  else
    echo -e "${RED}✗ Master API is NOT responding${NC}"
  fi
  
elif [ "$NODE_NAME" = "worker" ] || [ "$NODE_NAME" = "local-worker" ]; then
  if sudo systemctl is-active exo-worker.service > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Worker service is active${NC}"
  else
    echo -e "${RED}✗ Worker service is NOT active${NC}"
    echo "Service status:"
    sudo systemctl status exo-worker.service --no-pager || true
  fi
  
  # Try to connect to worker API
  echo ""
  echo -e "${YELLOW}Testing Worker API connectivity...${NC}"
  if curl -s http://localhost:52416/node_id > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Worker API is responding${NC}"
    echo "  Node ID: $(curl -s http://localhost:52416/node_id | jq -r '.node_id' 2>/dev/null || echo 'Unknown')"
  else
    echo -e "${RED}✗ Worker API is NOT responding${NC}"
  fi
  
else
  # Remote node
  if ssh -o ConnectTimeout=2 -o BatchMode=yes "bdeeley@$NODE_NAME" "systemctl is-active exo.service" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ $NODE_NAME service is active${NC}"
  else
    echo -e "${RED}✗ $NODE_NAME service is NOT active${NC}"
  fi
  
  # Check API
  echo ""
  echo -e "${YELLOW}Testing $NODE_NAME API connectivity...${NC}"
  if ssh -o ConnectTimeout=2 -o BatchMode=yes "bdeeley@$NODE_NAME" "curl -s http://localhost:52415/node_id" > /dev/null 2>&1; then
    echo -e "${GREEN}✓ $NODE_NAME API is responding${NC}"
  else
    echo -e "${RED}✗ $NODE_NAME API is NOT responding${NC}"
  fi
fi

echo ""
echo -e "${BLUE}STEP 6: Viewing service logs${NC}"

if [ "$NODE_NAME" = "master" ] || [ "$NODE_NAME" = "local-master" ]; then
  LOG_FILE="$LOG_DIR/master.log"
  echo -e "${YELLOW}Capturing master logs to: $LOG_FILE${NC}"
  sudo journalctl -u exo.service -n 200 --no-pager > "$LOG_FILE" 2>&1 || true
  
  # Show last 50 lines with verbose output markers
  echo ""
  echo -e "${YELLOW}Last 50 log lines (showing debug markers):${NC}"
  grep -E "BOOTSTRAP|LD_LIBRARY|SETTING UP|LOADING|✓|✗|ERROR|WARNING|🚀|📦|🔧|📝|🎨|🏃|🎯|🏁|👋" "$LOG_FILE" | tail -50 || tail -50 "$LOG_FILE"
  
elif [ "$NODE_NAME" = "worker" ] || [ "$NODE_NAME" = "local-worker" ]; then
  LOG_FILE="$LOG_DIR/worker.log"
  echo -e "${YELLOW}Capturing worker logs to: $LOG_FILE${NC}"
  sudo journalctl -u exo-worker.service -n 200 --no-pager > "$LOG_FILE" 2>&1 || true
  
  # Show last 50 lines with verbose output markers
  echo ""
  echo -e "${YELLOW}Last 50 log lines (showing debug markers):${NC}"
  grep -E "BOOTSTRAP|LD_LIBRARY|SETTING UP|LOADING|✓|✗|ERROR|WARNING|🚀|📦|🔧|📝|🎨|🏃|🎯|🏁|👋" "$LOG_FILE" | tail -50 || tail -50 "$LOG_FILE"
  
else
  LOG_FILE="$LOG_DIR/${NODE_NAME}.log"
  echo -e "${YELLOW}Capturing $NODE_NAME logs to: $LOG_FILE${NC}"
  ssh -o BatchMode=yes "bdeeley@$NODE_NAME" "sudo journalctl -u exo.service -n 200 --no-pager" > "$LOG_FILE" 2>&1 || true
  
  # Show last 50 lines with verbose output markers
  echo ""
  echo -e "${YELLOW}Last 50 log lines (showing debug markers):${NC}"
  grep -E "BOOTSTRAP|LD_LIBRARY|SETTING UP|LOADING|✓|✗|ERROR|WARNING|🚀|📦|🔧|📝|🎨|🏃|🎯|🏁|👋" "$LOG_FILE" | tail -50 || tail -50 "$LOG_FILE"
fi

echo ""
echo -e "${BLUE}STEP 7: Environment variables check${NC}"

if [ "$NODE_NAME" = "master" ] || [ "$NODE_NAME" = "worker" ] || [ "$NODE_NAME" = "local-master" ] || [ "$NODE_NAME" = "local-worker" ]; then
  echo -e "${YELLOW}Local environment:${NC}"
  echo "  CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES:-NOT SET}"
  echo "  LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-NOT SET}" | cut -c1-100
  echo "  NVIDIA libs exist:"
  ls -d /home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/*/lib 2>/dev/null | while read lib; do
    echo "    ✓ $lib"
  done || echo "    ✗ No NVIDIA libs found"
else
  echo -e "${YELLOW}Remote environment on $NODE_NAME:${NC}"
  ssh -o BatchMode=yes "bdeeley@$NODE_NAME" "echo 'CUDA_VISIBLE_DEVICES:' \$CUDA_VISIBLE_DEVICES && echo 'LD_LIBRARY_PATH:' \$LD_LIBRARY_PATH && ls -d /home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/*/lib 2>/dev/null | head -5 || echo '  ✗ No NVIDIA libs found'" || true
fi

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}Single node test complete. Logs saved to: $LOG_DIR${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}To view full logs:${NC}"
echo "  tail -f $LOG_DIR/*.log"
echo ""
echo -e "${YELLOW}To test model loading on this node manually:${NC}"
if [ "$NODE_NAME" = "master" ] || [ "$NODE_NAME" = "local-master" ]; then
  echo "  curl -X POST http://localhost:52415/place_instance -H 'Content-Type: application/json' -d '{\"model_id\": \"mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit\", \"instance_id\": \"test-$(date +%s)\", \"min_nodes\": 1}'"
elif [ "$NODE_NAME" = "worker" ] || [ "$NODE_NAME" = "local-worker" ]; then
  echo "  curl -X POST http://localhost:52416/place_instance ..."
else
  echo "  ssh bdeeley@$NODE_NAME 'curl -X POST http://localhost:52415/place_instance ...'"
fi
