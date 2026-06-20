#!/bin/bash

# ============================================================================
# EXO CLUSTER MASTER ORCHESTRATION SCRIPT
# ============================================================================
# Interactive interface for cluster management and troubleshooting
#
# Usage: exo-cluster.sh [command] [options]
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Helper functions
print_header() {
  echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
  echo -e "${MAGENTA}$1${NC}"
  echo -e "${MAGENTA}════════════════════════════════════════════════════════════${NC}"
}

print_menu_item() {
  echo -e "  ${CYAN}$1)${NC} $2"
}

print_success() {
  echo -e "${GREEN}✓${NC} $1"
}

print_error() {
  echo -e "${RED}✗${NC} $1"
}

show_main_menu() {
  print_header "EXO CLUSTER MANAGEMENT"
  echo ""
  echo "CLUSTER OPERATIONS:"
  print_menu_item "1" "Deploy/Setup all nodes"
  print_menu_item "2" "Start cluster"
  print_menu_item "3" "Stop cluster"
  print_menu_item "4" "Restart cluster"
  echo ""
  echo "MONITORING & DIAGNOSTICS:"
  print_menu_item "5" "Check cluster status"
  print_menu_item "6" "View recent logs"
  print_menu_item "7" "Run full diagnostics"
  echo ""
  echo "SINGLE NODE TROUBLESHOOTING:"
  print_menu_item "8" "Test master node"
  print_menu_item "9" "Test worker node"
  print_menu_item "a" "Test remote node (Theplague)"
  echo ""
  echo "UTILITIES:"
  print_menu_item "c" "View automation guide"
  print_menu_item "d" "View configuration"
  print_menu_item "e" "Open monitoring dashboard (GPU memory)"
  echo ""
  print_menu_item "q" "Quit"
  echo ""
}

show_single_node_menu() {
  echo ""
  echo -e "${YELLOW}Select node to test:${NC}"
  print_menu_item "1" "Master"
  print_menu_item "2" "Worker"
  print_menu_item "3" "Theplague (Remote)"
  print_menu_item "4" "All active nodes"
  print_menu_item "0" "Back"
  echo ""
}

# Command handlers
cmd_deploy() {
  echo ""
  echo -e "${YELLOW}This will:${NC}"
  echo "  1. Setup local master node"
  echo "  2. Setup local worker node"
  echo "  3. Deploy config to remote nodes"
  echo "  4. Setup all remote nodes"
  echo ""
  read -p "Continue? (y/n) " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    bash "$SCRIPT_DIR/deploy-all-nodes.sh"
    if [ $? -eq 0 ]; then
      print_success "Deployment complete"
    else
      print_error "Deployment failed"
    fi
  else
    echo "Cancelled"
  fi
}

cmd_start() {
  print_header "STARTING CLUSTER"
  bash "$SCRIPT_DIR/cluster-control.sh" start
}

cmd_stop() {
  echo ""
  read -p "Stop all cluster services? (y/n) " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    bash "$SCRIPT_DIR/cluster-control.sh" stop
    print_success "Cluster stopped"
  else
    echo "Cancelled"
  fi
}

cmd_restart() {
  echo ""
  read -p "Restart entire cluster? (y/n) " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    bash "$SCRIPT_DIR/cluster-control.sh" restart
  else
    echo "Cancelled"
  fi
}

cmd_status() {
  print_header "CLUSTER STATUS"
  bash "$SCRIPT_DIR/cluster-control.sh" status
}

cmd_logs() {
  print_header "RECENT LOGS"
  bash "$SCRIPT_DIR/cluster-control.sh" logs
  echo ""
  read -p "Press Enter to continue..."
}

cmd_diagnose() {
  echo ""
  echo -e "${YELLOW}Select diagnostic scope:${NC}"
  print_menu_item "1" "All nodes"
  print_menu_item "2" "Master only"
  print_menu_item "3" "Worker only"
  print_menu_item "4" "Theplague only"
  print_menu_item "0" "Cancel"
  echo ""
  read -p "Choice: " choice
  
  case "$choice" in
    1) bash "$SCRIPT_DIR/cluster-diagnose.sh" all ;;
    2) bash "$SCRIPT_DIR/cluster-diagnose.sh" master ;;
    3) bash "$SCRIPT_DIR/cluster-diagnose.sh" worker ;;
    4) bash "$SCRIPT_DIR/cluster-diagnose.sh" theplague ;;
    0) echo "Cancelled" ;;
    *) print_error "Invalid choice" ;;
  esac
  
  if [ "$choice" != "0" ]; then
    echo ""
    read -p "Press Enter to continue..."
  fi
}

cmd_test_single() {
  show_single_node_menu
  read -p "Choice: " choice
  
  case "$choice" in
    1) bash "$SCRIPT_DIR/test-single-node.sh" master ;;
    2) bash "$SCRIPT_DIR/test-single-node.sh" worker ;;
    3) bash "$SCRIPT_DIR/test-single-node.sh" theplague ;;
    4) 
      for node in master worker; do
        bash "$SCRIPT_DIR/test-single-node.sh" "$node"
        echo ""
      done
      bash "$SCRIPT_DIR/test-single-node.sh" theplague
      ;;
    0) echo "Cancelled" ;;
    *) print_error "Invalid choice" ;;
  esac
  
  if [ "$choice" != "0" ]; then
    echo ""
    read -p "Press Enter to continue..."
  fi
}

cmd_guide() {
  less "$SCRIPT_DIR/AUTOMATION-GUIDE.md"
}

cmd_config() {
  echo ""
  less "$SCRIPT_DIR/node-config.env"
}

cmd_dashboard() {
  echo ""
  print_header "GPU MEMORY MONITORING DASHBOARD"
  echo ""
  echo "Monitoring GPU memory usage across all nodes..."
  echo "Press Ctrl+C to stop"
  echo ""
  
  while true; do
    clear
    echo -e "${CYAN}$(date '+%Y-%m-%d %H:%M:%S')${NC} - GPU Memory Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Local GPUs
    echo -e "${YELLOW}maxpower (Local):${NC}"
    gpu0_used=$(nvidia-smi -i 0 --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null || echo "?")
    gpu0_total=$(nvidia-smi -i 0 --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || echo "?")
    [ "$gpu0_used" != "?" ] && gpu0_pct=$((gpu0_used * 100 / gpu0_total)) || gpu0_pct="?"
    
    gpu1_used=$(nvidia-smi -i 1 --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null || echo "?")
    gpu1_total=$(nvidia-smi -i 1 --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null || echo "?")
    [ "$gpu1_used" != "?" ] && gpu1_pct=$((gpu1_used * 100 / gpu1_total)) || gpu1_pct="?"
    
    printf "  GPU0 (RTX 3060):  %6s MB / %6s MB (%3s%%)\n" "$gpu0_used" "$gpu0_total" "$gpu0_pct"
    printf "  GPU1 (Quadro):    %6s MB / %6s MB (%3s%%)\n" "$gpu1_used" "$gpu1_total" "$gpu1_pct"
    
    echo ""
    
    # Remote GPUs
    echo -e "${YELLOW}theplague (Remote RTX 3060):${NC}"
    theplague_mem=$(ssh -o ConnectTimeout=1 -o BatchMode=yes bdeeley@172.16.0.29 \
      'nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits' 2>/dev/null || echo "?")
    printf "  GPU0:             %6s MB\n" "$theplague_mem"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Updating every 2 seconds... (Ctrl+C to exit)"
    
    sleep 2
  done
}

# ============================================================================
# Main Loop
# ============================================================================

if [ $# -gt 0 ]; then
  # Direct command execution
  case "$1" in
    deploy) cmd_deploy ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    diagnose) cmd_diagnose ;;
    test) cmd_test_single ;;
    guide) cmd_guide ;;
    config) cmd_config ;;
    dashboard) cmd_dashboard ;;
    *)
      echo "Unknown command: $1"
      echo ""
      echo "Usage: exo-cluster.sh [deploy|start|stop|restart|status|logs|diagnose|test|guide|config|dashboard]"
      exit 1
      ;;
  esac
else
  # Interactive menu
  while true; do
    clear
    show_main_menu
    read -p "Enter choice: " choice
    echo ""
    
    case "$choice" in
      1) cmd_deploy ;;
      2) cmd_start ;;
      3) cmd_stop ;;
      4) cmd_restart ;;
      5) cmd_status ;;
      6) cmd_logs ;;
      7) cmd_diagnose ;;
      8|9|a)
        case "$choice" in
          8) bash "$SCRIPT_DIR/test-single-node.sh" master ;;
          9) bash "$SCRIPT_DIR/test-single-node.sh" worker ;;
          a) bash "$SCRIPT_DIR/test-single-node.sh" theplague ;;
        esac
        echo ""
        read -p "Press Enter to continue..."
        ;;
      c) cmd_guide ;;
      d) cmd_config ;;
      e) cmd_dashboard ;;
      q) 
        echo "Goodbye!"
        exit 0
        ;;
      *)
        print_error "Invalid choice"
        sleep 2
        ;;
    esac
  done
fi
