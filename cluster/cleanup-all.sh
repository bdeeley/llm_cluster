#!/usr/bin/env bash
# COMPLETE SESSION CLEANUP - Run this before any startup to ensure clean slate
# This removes ALL exo state, event logs, and stale processes from active nodes

set -e

REMOTE_THEPLAGUE_IP="172.16.0.29"
MASTER_IP="172.16.0.28"

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║          COMPLETE CLUSTER CLEANUP - ACTIVE NODES              ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# ============================================================================
# PHASE 1: LOCAL CLEANUP (Master + Worker)
# ============================================================================
echo "PHASE 1: LOCAL CLEANUP (maxpower)"
echo "═══════════════════════════════════════════════════════════════════"

echo "  Stopping services..."
sudo systemctl stop exo.service 2>/dev/null || true
sudo systemctl stop exo-worker.service 2>/dev/null || true
sleep 1

echo "  Force killing all exo/uv processes..."
sudo pkill -9 exo || true
sudo pkill -9 "uv run" || true
sudo pkill -9 resource_tracker || true
sleep 1

echo "  Killing processes on cluster ports..."
for port in 52415 52416 5678 5680 5679; do
    sudo fuser -k ${port}/tcp 2>/dev/null || true
done
sleep 1

echo "  Removing event logs and caches..."
rm -rf ~/.local/share/exo/event_log* 2>/dev/null || true
rm -rf ~/.cache/exo* 2>/dev/null || true
rm -f ~/.cache/exo-*/.pid 2>/dev/null || true

echo "  Clearing node keypair state (fresh node IDs on restart)..."
rm -f ~/.config/exo/node_id-*.keypair.state 2>/dev/null || true

echo "  ✓ Local cleanup complete"
echo ""

# ============================================================================
# PHASE 2: THEPLAGUE CLEANUP (RTX 3060)
# ============================================================================
echo "PHASE 2: REMOTE CLEANUP - Theplague (${REMOTE_THEPLAGUE_IP})"
echo "═══════════════════════════════════════════════════════════════════"

ssh -o BatchMode=yes -o StrictHostKeyChecking=no bdeeley@${REMOTE_THEPLAGUE_IP} << 'THEPLAGUE_CLEANUP' 2>/dev/null || true
  echo "  Stopping service..."
  sudo systemctl stop exo.service 2>/dev/null || true
  sleep 1
  
  echo "  Force killing processes..."
  sudo pkill -9 exo || true
  sudo pkill -9 "uv run" || true
  sudo pkill -9 resource_tracker || true
  sleep 1
  
  echo "  Killing cluster ports..."
  sudo fuser -k 52415/tcp 2>/dev/null || true
  sudo fuser -k 5679/tcp 2>/dev/null || true
  sleep 1
  
  echo "  Removing event logs and caches..."
  rm -rf ~/.local/share/exo/event_log* 2>/dev/null || true
  rm -rf ~/.cache/exo* 2>/dev/null || true
  
  echo "  Clearing node keypair state..."
  rm -f ~/.config/exo/node_id-*.keypair.state 2>/dev/null || true
  
  echo "  ✓ Theplague cleanup complete"
THEPLAGUE_CLEANUP

echo ""

# ============================================================================
# PHASE 3: VERIFICATION
# ============================================================================
echo "PHASE 3: VERIFICATION"
echo "═══════════════════════════════════════════════════════════════════"

echo "  Verifying no exo processes running..."
LOCAL_PROCS=$(ps aux | grep -E "exo|uv run" | grep -v grep | wc -l)
if [ "$LOCAL_PROCS" -eq 0 ]; then
    echo "  ✓ Local: No exo processes"
else
    echo "  ✗ Local: Still has $LOCAL_PROCS exo processes"
fi

THEPLAGUE_PROCS=$(ssh -o BatchMode=yes bdeeley@${REMOTE_THEPLAGUE_IP} 'ps aux | grep -E "exo|uv run" | grep -v grep | wc -l' 2>/dev/null || echo "?")
if [ "$THEPLAGUE_PROCS" -eq 0 ]; then
    echo "  ✓ Theplague: No exo processes"
else
    echo "  ✗ Theplague: Still has $THEPLAGUE_PROCS exo processes"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  CLEANUP COMPLETE - Safe to start cluster                     ║"
echo "║  Next: ./cluster-control.sh start                             ║"
echo "╚════════════════════════════════════════════════════════════════╝"
