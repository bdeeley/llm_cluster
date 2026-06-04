#!/bin/bash

# tcpdump Network Diagnostics Script
# Captures all traffic on libp2p ports and API ports for all 4 nodes
# Saves to files for later analysis

set -e

CAPTURE_DIR="/tmp/exo-network-captures"
DURATION="${1:-60}"  # Capture for 60 seconds by default

mkdir -p "$CAPTURE_DIR"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  EXO CLUSTER NETWORK DIAGNOSTICS (tcpdump)                    ║"
echo "║  Duration: $DURATION seconds                                      ║"
echo "║  Ports monitored: 5678, 5679, 5680 (libp2p)                   ║"
echo "║                  52415, 52416 (API)                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Function to start tcpdump capture on a node
start_capture() {
    local host=$1
    local output_file=$2
    local ports=$3
    
    if [ "$host" = "local" ]; then
        echo "Starting local capture to $output_file..."
        sudo tcpdump -i any -w "$output_file" -G "$DURATION" -W 1 \
            "port ${ports}" >/dev/null 2>&1 &
        CAPTURE_PID=$!
        echo "  PID: $CAPTURE_PID"
    else
        echo "Starting capture on $host to $output_file..."
        ssh -o ConnectTimeout=5 "bdeeley@$host" \
            "sudo tcpdump -i any -w /tmp/capture.pcap -G $DURATION -W 1 \"port ${ports}\"" >/dev/null 2>&1 &
        sleep 1
        scp "bdeeley@$host:/tmp/capture.pcap" "$output_file" 2>/dev/null || true
        echo "  Data: $(ls -lh "$output_file" 2>/dev/null | awk '{print $5}' || echo 'pending')"
    fi
}

# Start captures on all nodes
start_capture "local" "$CAPTURE_DIR/maxpower.pcap" "5678 or 5680 or 52415 or 52416"
start_capture "172.16.0.175" "$CAPTURE_DIR/theplague.pcap" "5679 or 52415 or 52416"
start_capture "172.16.0.14" "$CAPTURE_DIR/debian.pcap" "5679 or 52415 or 52416"

echo ""
echo "Capturing network traffic for $DURATION seconds..."
sleep "$DURATION"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✓ Capture complete"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Captured files:"
ls -lh "$CAPTURE_DIR"/*.pcap 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
echo ""
echo "Analysis commands:"
echo "  tcpdump -r $CAPTURE_DIR/maxpower.pcap | head -30"
echo "  tcpdump -r $CAPTURE_DIR/theplague.pcap | grep -i connect"
echo ""
echo "Capture directory: $CAPTURE_DIR/"
