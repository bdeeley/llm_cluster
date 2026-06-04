#!/bin/bash
set -euo pipefail

# ============================================================================
# CLUSTER TROUBLESHOOTING AND DIAGNOSTICS
# ============================================================================
# Comprehensive diagnostics for the exo cluster
#
# Usage: cluster-diagnose.sh [node-name]
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/node-config.env"

source "$CONFIG_FILE"

TARGET_NODE="${1:-all}"
DIAG_DIR="/tmp/exo-diagnostics-$(date +%s)"
mkdir -p "$DIAG_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[⚠]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; }

echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}CLUSTER DIAGNOSTICS${NC}"
echo -e "${BLUE}Target: $TARGET_NODE${NC}"
echo -e "${BLUE}Diagnostics saved to: $DIAG_DIR${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"

# ============================================================================
# Local Diagnostics
# ============================================================================

diagnose_local() {
  local node_name=$1
  local log_file="$DIAG_DIR/${node_name}.log"
  
  echo ""
  log_info "Diagnosing LOCAL NODE ($node_name)..."
  {
    echo "═══════════════════════════════════════════════════════════"
    echo "LOCAL NODE DIAGNOSTICS: $node_name"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    echo "1. SYSTEM INFORMATION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    uname -a
    echo ""
    echo "Hostname: $(hostname)"
    echo "IP Addresses:"
    hostname -I
    echo ""
    
    echo "2. DIRECTORY STRUCTURE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ls -lh "$EXO_ROOT" 2>/dev/null | head -20 || echo "ERROR: $EXO_ROOT not found"
    echo ""
    ls -lhd "$CACHE_BASE"/exo* "$SHARE_BASE"/exo* 2>/dev/null | head -20 || echo "WARNING: No exo directories found"
    echo ""
    
    echo "3. PYTHON ENVIRONMENT"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Python: $EXO_VENV_PYTHON"
    "$EXO_VENV_PYTHON" --version 2>/dev/null || echo "ERROR: Python not found"
    echo ""
    echo "MLX Import Test:"
    "$EXO_VENV_PYTHON" -c "import mlx.core; print('  ✓ MLX imported successfully')" 2>&1 | grep -E "^  ✓|^  ✗|ModuleNotFoundError|ImportError" || echo "  ERROR: MLX import failed"
    echo ""
    
    echo "4. NVIDIA LIBRARIES"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    which nvidia-smi > /dev/null 2>&1 && nvidia-smi --version || echo "ERROR: nvidia-smi not found"
    echo ""
    echo "GPU Status:"
    nvidia-smi --query-gpu=index,name,memory.total,memory.used,utilization.gpu --format=csv 2>/dev/null || echo "ERROR: nvidia-smi query failed"
    echo ""
    
    echo "5. ENVIRONMENT VARIABLES"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "LD_LIBRARY_PATH: ${LD_LIBRARY_PATH:-NOT SET}"
    echo "CUDA_HOME: ${CUDA_HOME:-NOT SET}"
    echo "CUDA_VISIBLE_DEVICES: ${CUDA_VISIBLE_DEVICES:-NOT SET}"
    echo "HF_TOKEN: $([ -n "${HF_TOKEN:-}" ] && echo '***SET***' || echo 'NOT SET')"
    echo ""
    
    echo "6. SERVICE STATUS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    case "$node_name" in
      master)
        systemctl status exo.service 2>/dev/null | head -10 || echo "ERROR: Service not found"
        ;;
      worker)
        systemctl status exo-worker.service 2>/dev/null | head -10 || echo "ERROR: Service not found"
        ;;
    esac
    echo ""
    
    echo "7. RECENT LOGS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    case "$node_name" in
      master)
        sudo journalctl -u exo.service -n 30 --no-pager 2>/dev/null | head -40 || echo "ERROR: Cannot read logs"
        ;;
      worker)
        sudo journalctl -u exo-worker.service -n 30 --no-pager 2>/dev/null | head -40 || echo "ERROR: Cannot read logs"
        ;;
    esac
    echo ""
    
  } | tee "$log_file"
}

# ============================================================================
# Remote Diagnostics
# ============================================================================

diagnose_remote() {
  local node_name=$1
  local node_ip=$2
  local log_file="$DIAG_DIR/${node_name}.log"
  
  echo ""
  log_info "Diagnosing REMOTE NODE ($node_name @ $node_ip)..."
  {
    echo "═══════════════════════════════════════════════════════════"
    echo "REMOTE NODE DIAGNOSTICS: $node_name"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    echo "1. CONNECTIVITY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if ssh -o ConnectTimeout=2 -o BatchMode=yes "bdeeley@$node_name" "echo '✓ SSH connection OK'" 2>/dev/null; then
      echo ""
    else
      echo "ERROR: Cannot SSH to $node_name"
      return 1
    fi
    
    echo "2. PYTHON ENVIRONMENT"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ssh -o BatchMode=yes "bdeeley@$node_name" \
      "/home/bdeeley/exo/.venv/bin/python3 --version 2>&1 && /home/bdeeley/exo/.venv/bin/python3 -c 'import mlx.core; print(\"✓ MLX imported\")' 2>&1" || \
      echo "ERROR: MLX import failed"
    echo ""
    
    echo "3. NVIDIA SETUP"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ssh -o BatchMode=yes "bdeeley@$node_name" \
      "nvidia-smi --query-gpu=index,name,memory.total,memory.used --format=csv 2>/dev/null || echo 'ERROR: nvidia-smi failed'" || true
    echo ""
    
    echo "4. SERVICE STATUS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ssh -o BatchMode=yes "bdeeley@$node_name" \
      "systemctl status exo.service 2>/dev/null | head -10" || echo "ERROR: Service not found"
    echo ""
    
    echo "5. RECENT LOGS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    ssh -o BatchMode=yes "bdeeley@$node_name" \
      "sudo journalctl -u exo.service -n 30 --no-pager 2>/dev/null | head -40" || echo "ERROR: Cannot read logs"
    echo ""
    
  } | tee "$log_file"
}

# ============================================================================
# Main
# ============================================================================

case "$TARGET_NODE" in
  all)
    diagnose_local "master"
    diagnose_local "worker"
    
    while IFS=: read -r node_name node_ip node_port; do
      node_name=$(echo "$node_name" | xargs)
      node_ip=$(echo "$node_ip" | xargs)
      diagnose_remote "$node_name" "$node_ip"
    done <<< "$REMOTE_NODES"
    ;;
  master)
    diagnose_local "master"
    ;;
  worker)
    diagnose_local "worker"
    ;;
  *)
    # Assume it's a remote node name
    found=0
    while IFS=: read -r node_name node_ip node_port; do
      node_name=$(echo "$node_name" | xargs)
      node_ip=$(echo "$node_ip" | xargs)
      if [ "$node_name" = "$TARGET_NODE" ]; then
        diagnose_remote "$node_name" "$node_ip"
        found=1
        break
      fi
    done <<< "$REMOTE_NODES"
    
    if [ $found -eq 0 ]; then
      log_error "Unknown node: $TARGET_NODE"
    fi
    ;;
esac

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ DIAGNOSTICS COMPLETE${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Diagnostics saved to: $DIAG_DIR"
echo "View results: ls -lh $DIAG_DIR/"
