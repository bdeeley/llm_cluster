#!/bin/bash
set -euo pipefail

# ============================================================================
# STANDARDIZED NODE SETUP SCRIPT
# ============================================================================
# This script sets up a single exo node with standardized configuration
# Should be idempotent - safe to run multiple times
#
# Usage: setup-node.sh master|worker|remote [NODE_NAME]
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/node-config.env"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  exit 1
fi

source "$CONFIG_FILE"

NODE_TYPE="${1:-master}"
NODE_NAME="${2:-$(hostname -s)}"
VERBOSE="${VERBOSE:-1}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warning() { echo -e "${YELLOW}[⚠]${NC} $*"; }
log_error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}NODE STANDARDIZED SETUP${NC}"
echo -e "${BLUE}Node Type: $NODE_TYPE${NC}"
echo -e "${BLUE}Node Name: $NODE_NAME${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"

# ============================================================================
# STEP 1: Validate environment
# ============================================================================
log_info "Validating environment..."

if ! validate_paths; then
  log_error "Path validation failed"
fi

if ! validate_nvidia_libs; then
  log_warning "Some NVIDIA libraries missing - MLX may not work"
fi

log_success "Environment validation complete"

# ============================================================================
# STEP 2: Create standardized directory structure
# ============================================================================
log_info "Setting up directory structure..."

case "$NODE_TYPE" in
  master)
    mkdir -p "$LOG_MASTER" "$EVENT_LOG_MASTER"
    chown -R bdeeley:bdeeley "$(dirname $CACHE_MASTER)" "$(dirname $SHARE_MASTER)"
    chmod 755 "$LOG_MASTER" "$EVENT_LOG_MASTER"
    log_success "Master directories ready"
    ;;
  worker)
    mkdir -p "$LOG_WORKER" "$EVENT_LOG_WORKER"
    chown -R bdeeley:bdeeley "$(dirname $CACHE_WORKER)" "$(dirname $SHARE_WORKER)"
    chmod 755 "$LOG_WORKER" "$EVENT_LOG_WORKER"
    log_success "Worker directories ready"
    ;;
  remote)
    CACHE_REMOTE="${CACHE_REMOTE_TEMPLATE//{NODE_NAME}/$NODE_NAME}"
    SHARE_REMOTE="${SHARE_REMOTE_TEMPLATE//{NODE_NAME}/$NODE_NAME}"
    LOG_REMOTE="${LOG_REMOTE_TEMPLATE//{NODE_NAME}/$NODE_NAME}"
    EVENT_LOG_REMOTE="${EVENT_LOG_REMOTE_TEMPLATE//{NODE_NAME}/$NODE_NAME}"
    
    mkdir -p "$LOG_REMOTE" "$EVENT_LOG_REMOTE"
    chown -R bdeeley:bdeeley "$(dirname $CACHE_REMOTE)" "$(dirname $SHARE_REMOTE)"
    chmod 755 "$LOG_REMOTE" "$EVENT_LOG_REMOTE"
    log_success "Remote node ($NODE_NAME) directories ready"
    ;;
  *)
    log_error "Unknown node type: $NODE_TYPE"
    ;;
esac

# ============================================================================
# STEP 3: Generate systemd service file
# ============================================================================
log_info "Generating systemd service file..."

generate_service_file() {
  local type=$1
  local node_name=$2
  
  case "$type" in
    master)
      cat > /tmp/exo.service << 'EOF'
[Unit]
Description=exo distributed LLM inference (Master)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=bdeeley
WorkingDirectory=/home/bdeeley/exo
Environment="XDG_CACHE_HOME=/home/bdeeley/.cache/exo-master"
Environment="XDG_DATA_HOME=/home/bdeeley/.local/share/exo-master"
Environment="EXO_EVENT_LOG_DIR=/home/bdeeley/.local/share/exo-master/event_log"
Environment="CUDA_VISIBLE_DEVICES=0,1"
Environment="CUDA_HOME=/usr"
Environment="CUDA_PATH=/usr"
Environment="CPATH=/usr/include"
Environment="CPLUS_INCLUDE_PATH=/usr/include"
Environment="LD_LIBRARY_PATH=/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cublas/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cuda_nvrtc/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cudnn/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cufft/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nccl/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nvjitlink/lib"
Environment="OVERRIDE_MEMORY_MB=24000"
Environment="HF_TOKEN=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"
Environment="EXO_NODE_ID_KEYPAIR_PATH=/home/bdeeley/.config/exo/node_id-primary.keypair"
Environment="RUST_LOG=info"
ExecStart=/home/bdeeley/.local/bin/uv run exo --force-master --api-port 52415 --libp2p-port 5678 --bootstrap-peers /ip4/172.16.0.174/tcp/5678,/ip4/172.16.0.174/tcp/5680,/ip4/172.16.0.175/tcp/5679,/ip4/172.16.0.14/tcp/5679

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
      ;;
      
    worker)
      cat > /tmp/exo-worker.service << 'EOF'
[Unit]
Description=exo distributed LLM inference (Worker)
After=network-online.target exo.service
Wants=network-online.target
BindsTo=exo.service

[Service]
Type=simple
User=bdeeley
WorkingDirectory=/home/bdeeley/exo
Environment="XDG_CACHE_HOME=/home/bdeeley/.cache/exo-worker"
Environment="XDG_DATA_HOME=/home/bdeeley/.local/share/exo-worker"
Environment="EXO_EVENT_LOG_DIR=/home/bdeeley/.local/share/exo-worker/event_log"
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="CUDA_HOME=/usr"
Environment="CUDA_PATH=/usr"
Environment="CPATH=/usr/include"
Environment="CPLUS_INCLUDE_PATH=/usr/include"
Environment="LD_LIBRARY_PATH=/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cublas/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cuda_nvrtc/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cudnn/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cufft/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nccl/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nvjitlink/lib"
Environment="OVERRIDE_MEMORY_MB=20000"
Environment="HF_TOKEN=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"
Environment="RUST_LOG=info"
ExecStart=/home/bdeeley/.local/bin/uv run exo --api-port 52416 --libp2p-port 5680 --bootstrap-peers /ip4/172.16.0.174/tcp/5678,/ip4/172.16.0.174/tcp/5680,/ip4/172.16.0.175/tcp/5679,/ip4/172.16.0.14/tcp/5679

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
      ;;
      
    remote)
      cat > /tmp/exo.service << EOF
[Unit]
Description=exo distributed LLM inference (Remote: $node_name)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=bdeeley
WorkingDirectory=/home/bdeeley/exo
Environment="XDG_CACHE_HOME=/home/bdeeley/.cache/exo-${node_name}"
Environment="XDG_DATA_HOME=/home/bdeeley/.local/share/exo-${node_name}"
Environment="EXO_EVENT_LOG_DIR=/home/bdeeley/.local/share/exo-${node_name}/event_log"
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="CUDA_HOME=/usr"
Environment="CUDA_PATH=/usr"
Environment="CPATH=/usr/include"
Environment="CPLUS_INCLUDE_PATH=/usr/include"
Environment="LD_LIBRARY_PATH=/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cublas/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cuda_nvrtc/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cudnn/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cufft/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nccl/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nvjitlink/lib"
Environment="OVERRIDE_MEMORY_MB=20000"
Environment="HF_TOKEN=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"
Environment="RUST_LOG=info"
ExecStart=/home/bdeeley/.local/bin/uv run exo --api-port 52415 --libp2p-port 5679 --bootstrap-peers /ip4/172.16.0.174/tcp/5678,/ip4/172.16.0.174/tcp/5680,/ip4/172.16.0.175/tcp/5679,/ip4/172.16.0.14/tcp/5679

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
      ;;
  esac
}

generate_service_file "$NODE_TYPE" "$NODE_NAME"
log_success "Service file generated"

# ============================================================================
# STEP 4: Install service file
# ============================================================================
log_info "Installing service file..."

case "$NODE_TYPE" in
  master)
    sudo cp /tmp/exo.service /etc/systemd/system/exo.service
    sudo chmod 644 /etc/systemd/system/exo.service
    log_success "Master service installed"
    ;;
  worker)
    sudo cp /tmp/exo-worker.service /etc/systemd/system/exo-worker.service
    sudo chmod 644 /etc/systemd/system/exo-worker.service
    log_success "Worker service installed"
    ;;
  remote)
    sudo cp /tmp/exo.service /etc/systemd/system/exo.service
    sudo chmod 644 /etc/systemd/system/exo.service
    log_success "Remote service installed"
    ;;
esac

# ============================================================================
# STEP 5: Reload systemd
# ============================================================================
log_info "Reloading systemd..."
sudo systemctl daemon-reload
log_success "Systemd reloaded"

# ============================================================================
# STEP 6: Verify setup
# ============================================================================
log_info "Verifying setup..."

case "$NODE_TYPE" in
  master|remote)
    if ! systemctl list-unit-files | grep -q "exo.service"; then
      log_error "exo.service not found in systemd"
    fi
    log_success "exo.service registered"
    ;;
  worker)
    if ! systemctl list-unit-files | grep -q "exo-worker.service"; then
      log_error "exo-worker.service not found in systemd"
    fi
    log_success "exo-worker.service registered"
    ;;
esac

echo ""
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ NODE SETUP COMPLETE${NC}"
echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
case "$NODE_TYPE" in
  master)
    echo "  1. Start service: sudo systemctl start exo.service"
    echo "  2. Monitor logs: sudo journalctl -u exo.service -f"
    echo "  3. Check API: curl http://localhost:52415/node_id"
    ;;
  worker)
    echo "  1. Start service: sudo systemctl start exo-worker.service"
    echo "  2. Monitor logs: sudo journalctl -u exo-worker.service -f"
    echo "  3. Check API: curl http://localhost:52416/node_id"
    ;;
  remote)
    echo "  1. Start service: sudo systemctl start exo.service"
    echo "  2. Monitor logs: sudo journalctl -u exo.service -f"
    echo "  3. Check API: curl http://localhost:52415/node_id"
    ;;
esac
