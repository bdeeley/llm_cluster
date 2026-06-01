#!/usr/bin/env bash
# cluster/setup.sh — one-time setup on the local (maxpower) machine
# Run with: sudo ./setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="/etc/ollama-cluster"
BIN_DIR="/usr/local/bin"

echo "=== Ollama Cluster Setup ==="
echo

# ── Prereqs ────────────────────────────────────────────────────────────────────
echo "[1/5] Checking dependencies..."
for cmd in python3 curl getent; do
    command -v "$cmd" &>/dev/null || { echo "  MISSING: $cmd — install it first"; exit 1; }
done
echo "  OK"

# ── Config dir ────────────────────────────────────────────────────────────────
echo "[2/5] Creating /etc/ollama-cluster/..."
mkdir -p "$CONF_DIR"

if [[ ! -f "${CONF_DIR}/cluster.conf" ]]; then
    cat > "${CONF_DIR}/cluster.conf" <<'EOF'
# Ollama cluster node definitions
# Format: <node-name>  <hostname-or-ip>
# Use the hostname from each node's /etc/hostname (set by the live ISO build)
# If DNS doesn't resolve them, replace with direct IPs after first boot.
#
node-a  llm-node-a
node-b  llm-node-b
EOF
    echo "  Created ${CONF_DIR}/cluster.conf — edit with actual IPs/hostnames if needed"
else
    echo "  ${CONF_DIR}/cluster.conf already exists (not overwritten)"
fi

# Seed empty nodes.json (watchdog will populate)
[[ -f "${CONF_DIR}/nodes.json" ]] || echo '{"local":"http://localhost:11434"}' > "${CONF_DIR}/nodes.json"
echo "  OK"

# ── Install scripts ───────────────────────────────────────────────────────────
echo "[3/5] Installing scripts to ${BIN_DIR}..."
cp "${SCRIPT_DIR}/cluster-status" "${BIN_DIR}/cluster-status"
chmod +x "${BIN_DIR}/cluster-status"
echo "  cluster-status → ${BIN_DIR}/cluster-status"

# ── Install systemd services ──────────────────────────────────────────────────
echo "[4/5] Installing systemd services..."

for svc in ollama-proxy.service ollama-watchdog.service; do
    cp "${SCRIPT_DIR}/${svc}" "/etc/systemd/system/${svc}"
    echo "  Installed /etc/systemd/system/${svc}"
done

systemctl daemon-reload

systemctl enable --now ollama-watchdog.service
echo "  ollama-watchdog: enabled + started"

systemctl enable --now ollama-proxy.service
echo "  ollama-proxy:    enabled + started"

# ── Verify ────────────────────────────────────────────────────────────────────
echo "[5/5] Verifying proxy..."
sleep 3
if curl -sf --connect-timeout 5 "http://localhost:11435/api/tags" -o /dev/null 2>/dev/null; then
    echo "  Proxy on :11435 responding OK"
else
    echo "  Proxy not yet responding — check: journalctl -u ollama-proxy -n 20"
fi

echo
echo "=== Setup complete ==="
echo
echo "  Local Ollama (unchanged):  http://localhost:11434"
echo "  Cluster Proxy:             http://localhost:11435"
echo
echo "  Cline config:"
echo "    Keep existing models → point Cline at http://localhost:11434 (no change)"
echo "    Use remote models    → switch Cline base URL to http://localhost:11435"
echo "                           then use node-a/<model> or node-b/<model>"
echo
echo "  Once remote nodes are booted:"
echo "    cluster-status           # quick health check"
echo "    cluster-status --models  # show all available models per node"
echo
echo "  Edit node addresses: sudo nano ${CONF_DIR}/cluster.conf"
echo "  Force watchdog refresh: sudo systemctl restart ollama-watchdog"
