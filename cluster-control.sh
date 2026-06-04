#!/bin/bash
set -euo pipefail

# ============================================================================
# STANDARDIZED CLUSTER CONTROL SCRIPT
# ============================================================================
# Manages startup and shutdown of all cluster nodes in correct order
#
# Usage: cluster-control.sh [start|stop|restart|status|logs]
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/node-config.env"

source "$CONFIG_FILE"

ACTION="${1:-status}"

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

# ============================================================================
# Port and Process Management Functions
# ============================================================================

check_ports() {
  local node_name="$1"
  local api_port="$2"
  local libp2p_port="$3"
  
  local in_use=0
  
  if [ "$node_name" = "local" ]; then
    # Check local ports
    if lsof -i ":${api_port}" > /dev/null 2>&1; then
      log_warning "Port $api_port (API) in use on local machine"
      in_use=1
    fi
    if lsof -i ":${libp2p_port}" > /dev/null 2>&1; then
      log_warning "Port $libp2p_port (libp2p) in use on local machine"
      in_use=1
    fi
  else
    # Check remote ports via SSH
    if ssh -o BatchMode=yes -o ConnectTimeout=2 "bdeeley@$node_name" \
      "sudo lsof -i :${api_port} > /dev/null 2>&1" 2>/dev/null; then
      log_warning "Port $api_port (API) in use on $node_name"
      in_use=1
    fi
    if ssh -o BatchMode=yes -o ConnectTimeout=2 "bdeeley@$node_name" \
      "sudo lsof -i :${libp2p_port} > /dev/null 2>&1" 2>/dev/null; then
      log_warning "Port $libp2p_port (libp2p) in use on $node_name"
      in_use=1
    fi
  fi
  
  return $in_use
}

cleanup_ports() {
  local node_name="$1"
  local api_port="$2"
  
  log_warning "Cleaning up stuck processes on $node_name..."
  
  if [ "$node_name" = "local" ]; then
    # Kill stuck exo processes locally
    if lsof -i ":${api_port}" > /dev/null 2>&1; then
      log_info "  Killing stuck exo process on local port $api_port..."
      sudo killall -9 exo 2>/dev/null || true
      sleep 1
    fi
  else
    # Kill stuck exo processes on remote
    if ssh -o BatchMode=yes -o ConnectTimeout=2 "bdeeley@$node_name" \
      "sudo lsof -i :${api_port} > /dev/null 2>&1" 2>/dev/null; then
      log_info "  Killing stuck exo process on $node_name:$api_port..."
      ssh -o BatchMode=yes "bdeeley@$node_name" \
        "sudo killall -9 exo 2>/dev/null || true" 2>/dev/null
      sleep 1
    fi
  fi
  
  # Reset systemd failure counter
  if [ "$node_name" = "local" ]; then
    sudo systemctl reset-failed exo.service exo-worker.service 2>/dev/null || true
  else
    ssh -o BatchMode=yes "bdeeley@$node_name" \
      "sudo systemctl reset-failed exo.service 2>/dev/null || true" 2>/dev/null
  fi
  
  log_success "  Cleanup complete on $node_name"
}

verify_ports_free() {
  echo ""
  log_info "Verifying all ports are free..."
  
  local all_free=true
  
  # Check local ports
  if ! check_ports "local" 52415 5678; then
    cleanup_ports "local" 52415
    all_free=false
  fi
  if ! check_ports "local" 52416 5680; then
    cleanup_ports "local" 52416
    all_free=false
  fi
  
  # Check remote ports
  while IFS=: read -r node_name node_ip api_port; do
    node_name=$(echo "$node_name" | xargs)
    
    # Determine libp2p port based on node
    case "$node_name" in
      theplague)
        libp2p_port=5679
        ;;
      debian)
        libp2p_port=5679
        ;;
      *)
        continue
        ;;
    esac
    
    if ! check_ports "$node_name" "$api_port" "$libp2p_port"; then
      cleanup_ports "$node_name" "$api_port"
      all_free=false
    fi
  done <<< "theplague:172.16.0.175:52417
debian:172.16.0.14:52418"
  
  if [ "$all_free" = true ]; then
    log_success "All ports verified as free"
  fi
  
  echo ""
}

# ============================================================================
# Helper Functions
# ============================================================================

start_cluster() {
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}STARTING CLUSTER${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  
  # Verify all ports are free (cleanup if needed)
  verify_ports_free
  
  # Start remote nodes first
  log_info "Starting REMOTE NODES (let them discover each other)..."
  while IFS=: read -r node_name node_ip node_port; do
    node_name=$(echo "$node_name" | xargs)
    log_info "  Starting $node_name..."
    ssh -o BatchMode=yes -o ConnectTimeout=5 "bdeeley@$node_name" \
      "sudo systemctl daemon-reload && sudo systemctl start exo.service" 2>/dev/null &
  done <<< "$REMOTE_NODES"
  wait
  log_success "Remote nodes started"
  
  # Wait for remote discovery
  log_info "Waiting 15 seconds for remote peer discovery..."
  sleep 15
  
  # Start local master
  log_info "Starting LOCAL MASTER..."
  sudo systemctl daemon-reload
  sudo systemctl start exo.service
  sleep 5
  log_success "Master started"
  
  # Start local worker
  log_info "Starting LOCAL WORKER..."
  sudo systemctl start exo-worker.service
  sleep 5
  log_success "Worker started"
  
  # Wait for topology stabilization
  log_info "Waiting 30 seconds for topology stabilization..."
  sleep 30
  
  # Check final topology
  echo ""
  log_info "Final cluster topology:"
  curl -s http://localhost:52415/state 2>/dev/null | \
    jq '{nodes: (.nodeIdentities | length), edges: (.topology.connections | keys | length)}' || echo "  API not responding yet"
  
  echo ""
  echo -e "${GREEN}✓ CLUSTER STARTED${NC}"
}

stop_cluster() {
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}STOPPING CLUSTER${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  
  log_info "Stopping LOCAL SERVICES..."
  sudo systemctl stop exo-worker.service exo.service 2>/dev/null || true
  log_success "Local services stopped"
  
  log_info "Stopping REMOTE NODES..."
  while IFS=: read -r node_name node_ip node_port; do
    node_name=$(echo "$node_name" | xargs)
    ssh -o BatchMode=yes -o ConnectTimeout=5 "bdeeley@$node_name" \
      "sudo systemctl stop exo.service" 2>/dev/null &
  done <<< "$REMOTE_NODES"
  wait
  log_success "Remote nodes stopped"
  
  # Cleanup any stuck processes
  verify_ports_free

  sleep 2
  echo ""
  echo -e "${GREEN}✓ CLUSTER STOPPED${NC}"
}

restart_cluster() {
  log_info "Restarting cluster..."
  stop_cluster
  sleep 3
  start_cluster
}

status_cluster() {
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}CLUSTER STATUS${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  
  # Local status
  echo ""
  log_info "LOCAL SERVICES:"
  
  echo -n "  exo.service (master): "
  if systemctl is-active exo.service > /dev/null 2>&1; then
    echo -e "${GREEN}ACTIVE${NC}"
  else
    echo -e "${RED}INACTIVE${NC}"
  fi
  
  echo -n "  exo-worker.service (worker): "
  if systemctl is-active exo-worker.service > /dev/null 2>&1; then
    echo -e "${GREEN}ACTIVE${NC}"
  else
    echo -e "${RED}INACTIVE${NC}"
  fi
  
  # Remote status
  echo ""
  log_info "REMOTE NODES:"
  while IFS=: read -r node_name node_ip node_port; do
    node_name=$(echo "$node_name" | xargs)
    echo -n "  $node_name ($node_ip): "
    status=$(ssh -o BatchMode=yes -o ConnectTimeout=2 "bdeeley@$node_name" \
      "systemctl is-active exo.service 2>/dev/null" 2>/dev/null || echo "UNKNOWN")
    if [ "$status" = "active" ]; then
      echo -e "${GREEN}ACTIVE${NC}"
    else
      echo -e "${RED}$status${NC}"
    fi
  done <<< "$REMOTE_NODES"
  
  # API Status
  echo ""
  log_info "API CONNECTIVITY:"
  
  echo -n "  Master API (localhost:52415): "
  if curl -s http://localhost:52415/node_id > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
  else
    echo -e "${RED}✗${NC}"
  fi
  
  echo -n "  Worker API (localhost:52416): "
  if curl -s http://localhost:52416/node_id > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC}"
  else
    echo -e "${RED}✗${NC}"
  fi
  
  # Cluster topology
  echo ""
  log_info "CLUSTER TOPOLOGY:"
  curl -s http://localhost:52415/state 2>/dev/null | \
    jq '{nodes: (.nodeIdentities | length), edges: (.topology.connections | keys | length), instances: (.instances | length), runners: (.runners | length)}' || \
    echo "  Unable to retrieve topology"
}

logs_cluster() {
  log_info "Showing recent logs..."
  echo ""
  
  echo -e "${YELLOW}Master logs (last 50 lines):${NC}"
  sudo journalctl -u exo.service -n 50 --no-pager | tail -20
  
  echo ""
  echo -e "${YELLOW}Worker logs (last 50 lines):${NC}"
  sudo journalctl -u exo-worker.service -n 50 --no-pager | tail -20
}

ports_cluster() {
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}PORT STATUS CHECK${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  verify_ports_free
}

cleanup_cluster() {
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}CLEANING UP STUCK PROCESSES${NC}"
  echo -e "${BLUE}════════════════════════════════════════════════════════════${NC}"
  echo ""
  verify_ports_free
  log_success "Cleanup complete"
}

# ============================================================================
# Main
# ============================================================================

case "$ACTION" in
  start)
    start_cluster
    ;;
  stop)
    stop_cluster
    ;;
  restart)
    restart_cluster
    ;;
  status)
    status_cluster
    ;;
  logs)
    logs_cluster
    ;;
  ports)
    ports_cluster
    ;;
  cleanup)
    cleanup_cluster
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status|logs|ports|cleanup}"
    exit 1
    ;;
esac
