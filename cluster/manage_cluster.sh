#!/usr/bin/env bash
# Orchestrates the 4-node exo cluster startup and verification.

# ============================================================================
# COMMAND HANDLING (start/stop/cleanup)
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMAND="${1:-start}"

case "$COMMAND" in
    cleanup)
        echo "Running complete cluster cleanup..."
        bash "$SCRIPT_DIR/cleanup-all.sh"
        exit $?
        ;;
    start|stop)
        # Continue with normal operation
        ;;
    *)
        echo "Usage: $0 {start|stop|cleanup}"
        exit 1
        ;;
esac

# ============================================================================
# INITIALIZATION & CONFIGURATION
# ============================================================================

MASTER_FQDN="maxpower.deeleymotorsports.lan"
MASTER_IP=$(getent hosts "$MASTER_FQDN" | awk '{print $1}')
REMOTE_3060_FQDN="theplague.deeleymotorsports.lan"
REMOTE_3060_IP=$(getent hosts "$REMOTE_3060_FQDN" | awk '{print $1}')
REMOTE_3090_FQDN="debian.deeleymotorsports.lan"
REMOTE_3090_IP=$(getent hosts "$REMOTE_3090_FQDN" | awk '{print $1}')

API_PORT="52415"

# Auto-run cleanup before start
if [ "$COMMAND" = "start" ]; then
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║  Auto-running cleanup before startup...                       ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    bash "$SCRIPT_DIR/cleanup-all.sh"
    echo ""
    sleep 2
fi

# Validate all IPs are resolvable
if [ -z "$MASTER_IP" ] || [ -z "$REMOTE_3060_IP" ] || [ -z "$REMOTE_3090_IP" ]; then
    echo "ERROR: Could not resolve all FQDNs to IPs:"
    echo "  $MASTER_FQDN -> $MASTER_IP"
    echo "  $REMOTE_3060_FQDN -> $REMOTE_3060_IP"
    echo "  $REMOTE_3090_FQDN -> $REMOTE_3090_IP"
    exit 1
fi

echo "Cluster nodes (resolved):"
echo "  Master: $MASTER_FQDN -> $MASTER_IP"
echo "  Node 1: $REMOTE_3060_FQDN -> $REMOTE_3060_IP"
echo "  Node 2: $REMOTE_3090_FQDN -> $REMOTE_3090_IP"

# SSH helper: prefer passwordless (BatchMode) but fall back to interactive
ssh_run() {
    host="$1"
    shift
    cmd="$*"
    ssh -o ConnectTimeout=5 -o BatchMode=yes "$host" "$cmd" 2>/tmp/ssh_run_${host}.err || {
        echo "Warning: passwordless SSH to $host failed, attempting interactive SSH..."
        ssh -o ConnectTimeout=5 "$host" "$cmd"
    }
}

echo "[1/4] Cleaning stale processes..."
# Local cleanup: stop services and kill any surviving daemons or stale PIDs
sudo -n /usr/bin/systemctl stop exo.service exo-worker.service || true

# Force kill surviving daemons and multiprocessing helpers (SIGKILL)
pkill -9 -f exo || true
pkill -9 -f resource_tracker || true

# Identify and kill any process binding to critical cluster ports
for port in 52415 52416 5678 5680 5679; do
    sudo -n fuser -k ${port}/tcp 2>/dev/null || true
done

# Broad cleanup of pidfiles and caches
rm -f /home/bdeeley/.cache/exo-*/.pid /tmp/exo-*/exo/*.pid
rm -rf /home/bdeeley/.cache/exo-* 2>/dev/null || true

# Remote cleanup: stop systemd services and kill processes
echo "  Cleaning theplague..."
ssh_run $REMOTE_3060_FQDN "sudo systemctl stop exo.service 2>/dev/null; pkill -9 -f exo || true; pkill -9 -f resource_tracker || true; rm -rf ~/.cache/exo-*" || true

echo "  Cleaning debian..."
ssh_run $REMOTE_3090_FQDN "sudo systemctl stop exo.service 2>/dev/null; sudo pkill -9 -f exo || true; sudo pkill -9 -f resource_tracker || true; sudo rm -rf /home/bdeeley/.cache/exo-*" || true

sleep 2

# Update and reload local systemd services
echo "  Updating local systemd service files..."
sudo -n tee /etc/systemd/system/exo.service << EOF
[Unit]
Description=exo distributed LLM inference
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=bdeeley
WorkingDirectory=/home/bdeeley/exo
Environment="XDG_CACHE_HOME=/home/bdeeley/.cache/exo-master"
Environment="CUDA_VISIBLE_DEVICES=1"
Environment="CUDA_HOME=/usr"
Environment="CUDA_PATH=/usr"
Environment="CPATH=/usr/include"
Environment="CPLUS_INCLUDE_PATH=/usr/include"
Environment="LD_LIBRARY_PATH=/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cublas/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cuda_nvrtc/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cudnn/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cufft/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nccl/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nvjitlink/lib"
Environment="OVERRIDE_MEMORY_MB=24000"
Environment="EXO_NODE_ID_KEYPAIR_PATH=/home/bdeeley/.config/exo/node_id-primary.keypair"
ExecStart=/home/bdeeley/.local/bin/uv run exo --force-master --api-port 52415 --libp2p-port 5678 --bootstrap-peers /ip4/$REMOTE_3060_IP/tcp/5679,/ip4/$REMOTE_3090_IP/tcp/5679

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo -n tee /etc/systemd/system/exo-worker.service << EOF
[Unit]
Description=exo worker node (RTX 3060 GPU0)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=bdeeley
WorkingDirectory=/home/bdeeley/exo
Environment="XDG_CACHE_HOME=/home/bdeeley/.cache/exo-worker"
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="CUDA_HOME=/usr"
Environment="CUDA_PATH=/usr"
Environment="CPATH=/usr/include"
Environment="CPLUS_INCLUDE_PATH=/usr/include"
Environment="LD_LIBRARY_PATH=/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cublas/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cuda_nvrtc/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cudnn/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cufft/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nccl/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nvjitlink/lib"
Environment="OVERRIDE_MEMORY_MB=8000"
Environment="EXO_NODE_ID_KEYPAIR_PATH=/home/bdeeley/.config/exo/node_id-worker.keypair"
ExecStart=/home/bdeeley/.local/bin/uv run exo --no-master-candidate --api-port 52416 --libp2p-port 5680 --bootstrap-peers /ip4/$MASTER_IP/tcp/5678,/ip4/$REMOTE_3060_IP/tcp/5679,/ip4/$REMOTE_3090_IP/tcp/5679

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo -n /usr/bin/systemctl daemon-reload

echo "[2/4] Starting Master Nodes (maxpower)..."
# Stop any stale worker processes that might be holding pidfile
pkill -9 -f "exo.*--no-master-candidate" || true
sleep 1

sudo -n /usr/bin/systemctl start exo.service
echo "  Waiting for Master API on port $API_PORT..."
timeout=30
while ! curl -s -m 2 "http://localhost:$API_PORT/state" > /dev/null; do
    sleep 1
    ((timeout--))
    if [ $timeout -le 0 ]; then
        echo "ERROR: Master API failed to start within 30s"
        exit 1
    fi
done

# Give Master a moment to stabilize before adding local worker
sleep 2
sudo -n /usr/bin/systemctl start exo-worker.service

echo "[3/4] Starting Remote Nodes via systemd..."

# Create systemd service on theplague
echo "  Deploying exo.service to theplague..."
ssh -n $REMOTE_3060_FQDN "sudo tee /etc/systemd/system/exo.service > /dev/null" << 'THEPLAGUE_SERVICE'
[Unit]
Description=exo distributed LLM inference (RTX 4090)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=bdeeley
WorkingDirectory=/home/bdeeley/exo
Environment="XDG_CACHE_HOME=/home/bdeeley/.cache/exo-theplague"
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="CUDA_HOME=/usr"
Environment="CUDA_PATH=/usr"
Environment="CPATH=/usr/include"
Environment="CPLUS_INCLUDE_PATH=/usr/include"
Environment="LD_LIBRARY_PATH=/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cublas/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cuda_nvrtc/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cudnn/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cufft/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nccl/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nvjitlink/lib"
Environment="OVERRIDE_MEMORY_MB=24000"
Environment="EXO_NODE_ID_KEYPAIR_PATH=/home/bdeeley/.config/exo/node_id-theplague.keypair"
ExecStart=/home/bdeeley/.local/bin/uv run exo --api-port 52415 --libp2p-port 5679 --bootstrap-peers /ip4/$MASTER_IP/tcp/5678,/ip4/$MASTER_IP/tcp/5680,/ip4/$REMOTE_3090_IP/tcp/5679

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
THEPLAGUE_SERVICE

ssh -n $REMOTE_3060_FQDN "sudo systemctl daemon-reload && sudo systemctl restart exo.service" 2>&1 || echo "  Warning: Failed to start theplague service"

# Create systemd service on debian
echo "  Deploying exo.service to debian..."
ssh -n $REMOTE_3090_FQDN "sudo tee /etc/systemd/system/exo.service > /dev/null" << 'DEBIAN_SERVICE'
[Unit]
Description=exo distributed LLM inference (RTX 3090)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=bdeeley
WorkingDirectory=/home/bdeeley/exo
Environment="XDG_CACHE_HOME=/home/bdeeley/.cache/exo-debian"
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="CUDA_HOME=/usr"
Environment="CUDA_PATH=/usr"
Environment="CPATH=/usr/include"
Environment="CPLUS_INCLUDE_PATH=/usr/include"
Environment="LD_LIBRARY_PATH=/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cublas/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cuda_nvrtc/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cudnn/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cufft/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nccl/lib:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/nvjitlink/lib"
Environment="OVERRIDE_MEMORY_MB=24000"
Environment="EXO_NODE_ID_KEYPAIR_PATH=/home/bdeeley/.config/exo/node_id-debian.keypair"
ExecStart=/home/bdeeley/.local/bin/uv run exo --api-port 52415 --libp2p-port 5679 --bootstrap-peers /ip4/$MASTER_IP/tcp/5678,/ip4/$MASTER_IP/tcp/5680,/ip4/$REMOTE_3060_IP/tcp/5679

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
DEBIAN_SERVICE

ssh -n $REMOTE_3090_FQDN "sudo systemctl daemon-reload && sudo systemctl restart exo.service" 2>&1 || echo "  Warning: Failed to start debian service"

echo "[4/4] Verifying Cluster Topology..."
echo "  Waiting for nodes to join (up to 120s)..."
timeout=120
NODE_COUNT=0
while [ "$NODE_COUNT" -lt 4 ] && [ "$timeout" -gt 0 ]; do
    NODE_COUNT=$(curl -s -m 2 "http://localhost:$API_PORT/state" 2>/dev/null | jq -r '.nodeIdentities | length' 2>/dev/null)
    NODE_COUNT=${NODE_COUNT:-0}
    if [ "$NODE_COUNT" -eq 4 ]; then
        break
    fi
    sleep 3
    timeout=$((timeout - 3))
    echo -n "."
done
echo ""

if [ "$NODE_COUNT" -eq 4 ]; then
    echo "SUCCESS: 4 nodes detected in the ring."
    curl -s "http://localhost:$API_PORT/state" | jq '.nodeIdentities[] | {id: .id, name: .friendlyName}'
else
    echo "ERROR: Expected 4 nodes, but found $NODE_COUNT. Diagnostic dump follows:"
    echo "--- Full API State Response ---"
    curl -s "http://localhost:$API_PORT/state" | jq '.' || echo "Failed to fetch/parse state"
    echo "--- Local Status ---"
    systemctl status exo.service exo-worker.service --no-pager
    echo "--- Local Port Check ---"
    ss -ltnp | grep -E ':(52415|52416|5678|5679|5680)\b' || echo "No cluster ports listening locally"
    echo "--- Remote Process Check ---"
    echo -n "theplague: "; ssh_run $REMOTE_3060_FQDN "pgrep -a -f exo || echo 'NOT RUNNING'"
    echo -n "debian:    "; ssh_run $REMOTE_3090_FQDN "pgrep -a -f exo || echo 'NOT RUNNING'"
    echo "--- Remote Port Check ---"
    echo -n "theplague: "; ssh_run $REMOTE_3060_FQDN "ss -ltnp | grep -E ':(52415|5679)\b' || echo 'No ports listening'"
    echo -n "debian:    "; ssh_run $REMOTE_3090_FQDN "ss -ltnp | grep -E ':(52415|5679)\b' || echo 'No ports listening'"
    echo "--- Remote (theplague) Log Snippet ---"
    ssh_run $REMOTE_3060_FQDN "tail -n 20 /BIGMIRROR/exo-theplague.log"
    echo "--- Remote (debian) Log Snippet ---"
    ssh_run $REMOTE_3090_FQDN "sudo journalctl -u exo-remote-3090.service -n 20 --no-pager"
fi
echo ""
echo "======================================================================="
echo "CLUSTER STARTUP COMPLETE - PROCEEDING WITH MODEL DEPLOYMENT"
echo "======================================================================="
echo ""

# Place model instance across all 4 nodes
echo "[5/5] Placing Llama model across all 4 GPUs..."
INSTANCE_ID="llama-nano-4gpu-$(date +%s)"
PLACE_RESPONSE=$(curl -s -X POST "http://localhost:$API_PORT/place_instance" \
  -H "Content-Type: application/json" \
  -d "{\"model_id\": \"mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit\", \"instance_id\": \"$INSTANCE_ID\"}")

echo "  Instance ID: $INSTANCE_ID"
echo "  Response: $(echo "$PLACE_RESPONSE" | jq -c '.message')"

echo "  Waiting for model to load and runners to initialize (30s)..."
sleep 30

# Verify model placement
RUNNERS_COUNT=$(curl -s "http://localhost:$API_PORT/state" | jq -r '.runners | length' 2>/dev/null || echo "0")
INSTANCES=$(curl -s "http://localhost:$API_PORT/state" | jq -r '.instances | keys | length' 2>/dev/null || echo "0")

echo "  Active instances: $INSTANCES"
echo "  Active runners: $RUNNERS_COUNT"

if [ "$RUNNERS_COUNT" -gt 0 ]; then
    echo "✓ Model successfully deployed to cluster"
else
    echo "⚠ No runners detected - model may still be loading"
fi

echo ""
echo "======================================================================="
echo "CLUSTER READY - 4 NODES OPERATIONAL WITH DISTRIBUTED MODEL"
echo "======================================================================="
echo ""
echo "Cluster Summary:"
echo "  Master:  maxpower (172.16.0.174, RTX 3090 GPU1)"
echo "  Worker:  maxpower local (172.16.0.174, RTX 3060 GPU0)"  
echo "  Remote1: theplague (172.16.0.175, RTX 4090)"
echo "  Remote2: debian (172.16.0.14, RTX 3090)"
echo ""
echo "API Endpoint: http://localhost:52415"
echo "Model: mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit (4.8GB)"
echo ""
echo "Example usage:"
echo "  curl -X POST http://localhost:52415/v1/chat/completions \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"model\": \"mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello\"}], \"max_tokens\": 100}'"
echo ""
