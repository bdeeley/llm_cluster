#!/bin/bash

# Comprehensive Log Monitoring Script for active EXO cluster
# Shows all [TASK DISPATCH], [RUNNER], [RANK], and diagnostic messages in real-time
# Usage: ./monitor-logs.sh

set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  EXO CLUSTER LOG MONITORING SYSTEM                            ║"
echo "║  Capturing: Task Dispatch | Runner Events | Distributed Init  ║"
echo "║  Nodes: maxpower (master+worker) | theplague                  ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Starting log monitors in background..."
echo ""

LOG_DIR="/tmp/exo-cluster-logs"
mkdir -p "$LOG_DIR"

# Function to monitor and filter logs for a given service/host
monitor_service() {
    local service=$1
    local host=$2
    local output_file=$3
    
    if [ "$host" = "local" ]; then
        # Local services - use journalctl
        sudo journalctl -u "$service" -f --output=short-iso 2>/dev/null | while read -r line; do
            # Filter for diagnostic messages
            if echo "$line" | grep -qE "\[TASK DISPATCH\]|\[RUNNER\]|\[RANK|\[PLAN CYCLE\]|\[BOOTSTRAP\]|\[TASK DELIVERY\]|Error|Failed|TIMEOUT"; then
                echo "[$(hostname -s):$service] $line" >> "$output_file"
                echo "[$(hostname -s):$service] $line"
            fi
        done &
    else
        # Remote services - SSH to host
        ssh -o ConnectTimeout=5 "bdeeley@$host" "sudo journalctl -u exo.service -f --output=short-iso 2>/dev/null" | while read -r line; do
            if echo "$line" | grep -qE "\[TASK DISPATCH\]|\[RUNNER\]|\[RANK|\[PLAN CYCLE\]|\[BOOTSTRAP\]|\[TASK DELIVERY\]|Error|Failed|TIMEOUT"; then
                echo "[$host:exo] $line" >> "$output_file"
                echo "[$host:exo] $line"
            fi
        done &
    fi
}

# Start monitors
monitor_service "exo.service" "local" "$LOG_DIR/master.log"
monitor_service "exo-worker.service" "local" "$LOG_DIR/worker.log"
monitor_service "exo.service" "172.16.0.29" "$LOG_DIR/theplague.log"

sleep 1

echo "════════════════════════════════════════════════════════════════"
echo "✓ Log monitoring started"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "LEGEND:"
echo "  [TASK DISPATCH]  → Task being sent from master to runner"
echo "  [TASK DISPATCH ERROR] → Task dispatch failed"
echo "  [RUNNER QUEUE]   → Task received by runner process"
echo "  [RANK N]         → Distributed model initialization at rank N"
echo "  [TASK DELIVERY]  → Task successfully delivered"
echo "  Error/Failed     → Any error condition"
echo ""
echo "Logs being collected to: $LOG_DIR/"
echo ""
echo "Press Ctrl+C to stop"
echo ""

# Keep script running
wait
