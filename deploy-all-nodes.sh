#!/bin/bash
set -euo pipefail

# ============================================================================
# DEPLOY SETUP TO ALL NODES
# ============================================================================
# This script pushes standardized configuration to all nodes and sets them up
#
# Usage: deploy-all-nodes.sh [--skip-remotes] [--skip-validation]
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/node-config.env"
SETUP_SCRIPT="${SCRIPT_DIR}/setup-node.sh"
TEST_SCRIPT="${SCRIPT_DIR}/test-single-node.sh"

source "$CONFIG_FILE"

SKIP_REMOTES=0
SKIP_VALIDATION=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-remotes) SKIP_REMOTES=1; shift ;;
    --skip-validation) SKIP_VALIDATION=1; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[⚠]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}DEPLOY STANDARDIZED SETUP TO ALL NODES${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"

# ============================================================================
# STEP 1: Validate files
# ============================================================================
log_info "Validating deployment files..."

for file in "$CONFIG_FILE" "$SETUP_SCRIPT" "$TEST_SCRIPT"; do
  if [ ! -f "$file" ]; then
    log_error "Missing file: $file"
  fi
done

log_success "All files present"

# ============================================================================
# STEP 2: Setup local nodes
# ============================================================================
log_info "Setting up LOCAL MASTER..."
sudo bash "$SETUP_SCRIPT" master master || log_error "Master setup failed"
log_success "Master configured"

log_info "Setting up LOCAL WORKER..."
sudo bash "$SETUP_SCRIPT" worker worker || log_error "Worker setup failed"
log_success "Worker configured"

# ============================================================================
# STEP 3: Setup remote nodes
# ============================================================================
if [ $SKIP_REMOTES -eq 0 ]; then
  log_info "Setting up REMOTE NODES..."
  
  while IFS=: read -r node_name node_ip node_port; do
    node_name=$(echo "$node_name" | xargs)  # trim whitespace
    node_ip=$(echo "$node_ip" | xargs)
    
    log_info "Deploying to $node_name ($node_ip)..."
    
    # Copy config files
    scp -o BatchMode=yes -q "$CONFIG_FILE" "bdeeley@$node_ip:$SCRIPT_DIR/" 2>/dev/null || \
      log_error "Failed to copy config to $node_name"
    
    scp -o BatchMode=yes -q "$SETUP_SCRIPT" "bdeeley@$node_ip:$SCRIPT_DIR/" 2>/dev/null || \
      log_error "Failed to copy setup script to $node_name"
    
    # Run setup on remote
    ssh -o BatchMode=yes "bdeeley@$node_ip" \
      "sudo bash $SCRIPT_DIR/setup-node.sh remote $node_name" 2>/dev/null || \
      log_error "Setup failed on $node_name"
    
    log_success "$node_name configured"
  done <<< "$REMOTE_NODES"
  
else
  log_warning "Skipping remote node setup"
fi

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ DEPLOYMENT COMPLETE${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Configuration Summary:${NC}"
echo "  Master: $MASTER_HOST ($MASTER_IP)"
echo "  Worker: $WORKER_HOST ($WORKER_IP)"
echo "  Remotes: $(echo "$REMOTE_NODES" | tr '\n' ' ' | sed 's/ /, /g')"
echo ""
echo -e "${YELLOW}To verify setup on each node:${NC}"
echo "  bash $TEST_SCRIPT master"
echo "  bash $TEST_SCRIPT worker"
echo "  bash $TEST_SCRIPT theplague"
echo ""
echo -e "${YELLOW}To start the cluster:${NC}"
echo "  bash ${SCRIPT_DIR}/start-cluster.sh"
