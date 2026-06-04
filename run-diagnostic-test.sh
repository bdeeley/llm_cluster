#!/bin/bash

# Comprehensive 4-Node EXO Cluster Test with Full Diagnostics
# This script orchestrates the entire test with logging, network capture, and monitoring

set -e

TEST_DIR="/home/bdeeley/test"
RESULTS_DIR="/tmp/exo-test-results-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  4-NODE EXO CLUSTER COMPREHENSIVE DIAGNOSTIC TEST            ║"
echo "║  Results directory: $RESULTS_DIR                              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Phase 1: Prepare
echo "[PHASE 1] Preparing cluster..."
cd "$TEST_DIR"

echo "  [1a] Stopping all services..."
bash cluster-control.sh stop 2>&1 | tail -3
sleep 3

echo "  [1b] Clearing event logs..."
sudo rm -rf /home/bdeeley/.local/share/exo-master/event_log
sudo rm -rf /home/bdeeley/.local/share/exo-worker/event_log
sudo mkdir -p /home/bdeeley/.local/share/exo-master/event_log
sudo mkdir -p /home/bdeeley/.local/share/exo-worker/event_log
sudo chown -R bdeeley:bdeeley /home/bdeeley/.local/share/exo-* 2>/dev/null

echo "  [1c] Reloading systemd with enhanced logging configuration..."
sudo systemctl daemon-reload
echo "  ✓ Cluster prepared"
echo ""

# Phase 2: Start services and capture logs
echo "[PHASE 2] Starting services with diagnostic logging..."
echo "  [2a] Starting cluster..."
bash cluster-control.sh start 2>&1 | tail -3
sleep 20
echo "  [2b] Services started, topology stabilizing..."
sleep 10
echo "  ✓ All services online"
echo ""

# Phase 3: Check topology
echo "[PHASE 3] Verifying cluster topology..."
NODES=$(curl -s "http://localhost:52415/state" 2>/dev/null | jq '.nodeIdentities | length' 2>/dev/null || echo "?")
EDGES=$(curl -s "http://localhost:52415/state" 2>/dev/null | jq '.topology.connections | keys | length' 2>/dev/null || echo "?")
echo "  Nodes in cluster: $NODES"
echo "  Topology edges: $EDGES"

if [ "$NODES" != "4" ]; then
    echo "  ✗ ERROR: Expected 4 nodes, got $NODES"
    echo "  Dumping cluster state:"
    curl -s "http://localhost:52415/state" 2>/dev/null | jq '.' | head -50
    exit 1
fi
echo "  ✓ Topology valid"
echo ""

# Phase 4: Start network capture (background)
echo "[PHASE 4] Starting network capture..."
echo "  Capturing on libp2p ports (5678, 5679, 5680) and API ports (52415, 52416)..."
sudo timeout 120 tcpdump -i any -w "$RESULTS_DIR/network.pcap" \
    "port 5678 or port 5679 or port 5680 or port 52415 or port 52416" \
    >/dev/null 2>&1 &
TCPDUMP_PID=$!
echo "  tcpdump PID: $TCPDUMP_PID"
echo "  ✓ Network capture started"
echo ""

# Phase 5: Send model placement request
echo "[PHASE 5] Sending 4-node placement request..."
INST_ID="test-4node-$(date +%s)"
echo "  Instance ID: $INST_ID"
PLACE_RESPONSE=$(curl -s -X POST "http://localhost:52415/place_instance" \
  -H "Content-Type: application/json" \
  -d "{\"model_id\": \"mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit\", \"instance_id\": \"$INST_ID\", \"min_nodes\": 4}" 2>/dev/null)
echo "  Response: $PLACE_RESPONSE"
echo "  ✓ Placement request sent"
echo ""

# Phase 6: Monitor runner startup
echo "[PHASE 6] Monitoring 4-node instance loading (120 second timeout)..."
for elapsed in $(seq 1 120); do
    runners=$(curl -s "http://localhost:52415/state" 2>/dev/null | jq '.runners | length' 2>/dev/null || echo "?")
    ready=$(curl -s "http://localhost:52415/state" 2>/dev/null | jq '[.runners[] | select(. | keys[0] == "RunnerReady")] | length' 2>/dev/null || echo "?")
    
    printf "  [%3ds] Runners: %s/4 | Ready: %s/4" "$elapsed" "$runners" "$ready"
    
    if [ "$runners" = "4" ] && [ "$ready" = "4" ]; then
        echo ""
        echo "  ✓ 4-NODE MODEL LOADED!"
        break
    fi
    echo ""
    sleep 1
done

if [ "$runners" != "4" ] || [ "$ready" != "4" ]; then
    echo ""
    echo "  ✗ TIMEOUT: Only $runners runners, $ready ready"
fi
echo ""

# Phase 7: Collect logs
echo "[PHASE 7] Collecting diagnostic logs from all nodes..."

echo "  [7a] Local master logs..."
sudo journalctl -u exo.service -n 200 --no-pager > "$RESULTS_DIR/master-logs.txt" 2>&1
echo "    $(wc -l < "$RESULTS_DIR/master-logs.txt") lines"

echo "  [7b] Local worker logs..."
sudo journalctl -u exo-worker.service -n 200 --no-pager > "$RESULTS_DIR/worker-logs.txt" 2>&1
echo "    $(wc -l < "$RESULTS_DIR/worker-logs.txt") lines"

echo "  [7c] Remote node logs..."
ssh -o ConnectTimeout=2 bdeeley@172.16.0.175 "sudo journalctl -u exo.service -n 200 --no-pager" > "$RESULTS_DIR/theplague-logs.txt" 2>&1 || echo "    [unable to connect]"
[ -f "$RESULTS_DIR/theplague-logs.txt" ] && echo "    $(wc -l < "$RESULTS_DIR/theplague-logs.txt") lines"

ssh -o ConnectTimeout=2 bdeeley@172.16.0.14 "sudo journalctl -u exo.service -n 200 --no-pager" > "$RESULTS_DIR/debian-logs.txt" 2>&1 || echo "    [unable to connect]"
[ -f "$RESULTS_DIR/debian-logs.txt" ] && echo "    $(wc -l < "$RESULTS_DIR/debian-logs.txt") lines"

echo "  ✓ Logs collected"
echo ""

# Phase 8: Summary
echo "════════════════════════════════════════════════════════════════"
echo "TEST COMPLETE"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Results saved to: $RESULTS_DIR"
echo ""
echo "Key diagnostics:"
echo "  - Grep for [TASK DISPATCH]: grep '[TASK DISPATCH]' $RESULTS_DIR/*.txt"
echo "  - Grep for [RUNNER]: grep '[RUNNER]' $RESULTS_DIR/*.txt"
echo "  - Grep for [RANK: grep '[RANK' $RESULTS_DIR/*.txt"
echo "  - Network capture: tcpdump -r $RESULTS_DIR/network.pcap | head -50"
echo ""
echo "Summary:"
grep -h "\[TASK DISPATCH\]" "$RESULTS_DIR"/*.txt 2>/dev/null | wc -l | xargs echo "  Task dispatches:"
grep -h "RunnerReady" "$RESULTS_DIR"/*.txt 2>/dev/null | wc -l | xargs echo "  RunnerReady events:"
grep -h "ERROR\|TIMEOUT\|Failed" "$RESULTS_DIR"/*.txt 2>/dev/null | head -5 | xargs -I {} echo "  Sample errors: {}"
echo ""

kill $TCPDUMP_PID 2>/dev/null || true
echo "✓ All diagnostics complete"
