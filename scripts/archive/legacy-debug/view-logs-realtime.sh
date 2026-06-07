#!/bin/bash

# Real-time Diagnostic Log Viewer
# Shows all critical diagnostic logs from all 4 nodes
# Usage: ./view-logs-realtime.sh [service-name]

SERVICE="${1:-exo.service}"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  REAL-TIME EXO DIAGNOSTIC LOGS ($SERVICE)                   ║"
echo "║  Showing: Task Dispatch | Runner Queue | Distributed Init     ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "Legend:"
echo -e "  ${GREEN}[TASK DISPATCH]${NC}      = Task sent from master to runner"
echo -e "  ${YELLOW}[RUNNER QUEUE]${NC}      = Task received by runner"
echo -e "  ${BLUE}[RANK N]${NC}            = Distributed initialization at rank N"
echo -e "  ${RED}ERROR/TIMEOUT${NC}        = Failure conditions"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo ""

# Display logs from all sources
(
    # Local master
    echo "--- MAXPOWER MASTER (exo.service) ---"
    sudo journalctl -u exo.service -n 50 --no-pager 2>/dev/null | tail -20
    echo ""
    
    # Local worker
    echo "--- MAXPOWER WORKER (exo-worker.service) ---"
    sudo journalctl -u exo-worker.service -n 50 --no-pager 2>/dev/null | tail -20
    echo ""
    
    # Remote nodes
    echo "--- THEPLAGUE (172.16.0.175) ---"
    ssh -o ConnectTimeout=2 bdeeley@172.16.0.175 "sudo journalctl -u exo.service -n 50 --no-pager" 2>/dev/null | tail -20 || echo "  [Unable to connect]"
    echo ""
    
    echo "--- DEBIAN (172.16.0.14) ---"
    ssh -o ConnectTimeout=2 bdeeley@172.16.0.14 "sudo journalctl -u exo.service -n 50 --no-pager" 2>/dev/null | tail -20 || echo "  [Unable to connect]"
) | while IFS= read -r line; do
    if echo "$line" | grep -q "\[TASK DISPATCH\]"; then
        echo -e "${GREEN}$line${NC}"
    elif echo "$line" | grep -q "\[TASK DISPATCH ERROR\]"; then
        echo -e "${RED}$line${NC}"
    elif echo "$line" | grep -q "\[RUNNER\]"; then
        echo -e "${YELLOW}$line${NC}"
    elif echo "$line" | grep -q "\[RANK"; then
        echo -e "${BLUE}$line${NC}"
    elif echo "$line" | grep -qiE "error|failed|timeout"; then
        echo -e "${RED}$line${NC}"
    else
        echo "$line"
    fi
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "For continuous monitoring, use:"
echo "  sudo journalctl -u exo.service -f"
echo "  ssh theplague 'sudo journalctl -u exo.service -f'"
