#!/usr/bin/env bash
# =============================================================================
# /opt/node-setup.sh  (Ubuntu 24.04 version)
# Runs once on first boot via llm-node-setup.service.
#
# Key difference from Debian version:
#   nvidia-driver-550-open ships PRE-COMPILED kernel modules.
#   No DKMS compilation step. First boot is fast (~30 seconds).
# =============================================================================
set -euo pipefail

LOG="/var/log/llm-node-setup.log"
exec > >(tee -a "$LOG") 2>&1

source /etc/llm-node.conf

echo "=========================================="
echo " LLM Node Setup (Ubuntu) — $(date)"
echo " Host: ${NODE_HOSTNAME}  GPU: ${GPU_MODEL}"
echo "=========================================="

# ── 1. Load NVIDIA modules (pre-compiled, no DKMS needed) ────────────────────
echo "[1/6] Loading NVIDIA kernel modules..."
modprobe nvidia      || echo "WARN: modprobe nvidia failed"
modprobe nvidia_uvm  || true
modprobe nvidia_drm  || true

# Confirm GPU is visible
if nvidia-smi; then
    echo "NVIDIA driver OK"
else
    echo "WARN: nvidia-smi failed — trying ubuntu-drivers as fallback..."
    ubuntu-drivers autoinstall 2>&1 || true
    echo "Reboot may be required for driver to take effect."
fi

# ── 2. Install exo + torch ────────────────────────────────────────────────────
echo "[2/6] Installing exo distributed inference..."
if [[ ! -f /opt/exo-env/bin/exo ]]; then
    /opt/exo-env/bin/pip install --quiet exo-explore 2>/dev/null \
        || /opt/exo-env/bin/pip install --quiet \
               "git+https://github.com/exo-explore/exo.git" 2>/dev/null \
        || echo "WARN: exo install failed — distributed inference unavailable"
fi
if [[ -f /opt/exo-env/bin/exo ]] && ! /opt/exo-env/bin/python3 -c "import torch" 2>/dev/null; then
    /opt/exo-env/bin/pip install --quiet torch \
        --index-url https://download.pytorch.org/whl/cu124 2>/dev/null \
        || echo "WARN: torch install failed — exo may not use GPU"
fi

# ── 3. Configure Ollama ───────────────────────────────────────────────────────
echo "[3/6] Configuring Ollama..."
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf << EOF
[Service]
Environment="OLLAMA_HOST=0.0.0.0:${OLLAMA_PORT}"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_NUM_GPU=1"
EOF
systemctl daemon-reload
systemctl enable --now ollama-node.service

# Wait for Ollama to be ready
echo "  Waiting for Ollama on port ${OLLAMA_PORT}..."
for i in $(seq 1 30); do
    curl -sf "http://localhost:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1 && break
    sleep 2
done

# ── 4. Pull a starter model ───────────────────────────────────────────────────
echo "[4/6] Pulling starter model (qwen2.5-coder:7b)..."
OLLAMA_HOST="http://localhost:${OLLAMA_PORT}" ollama pull qwen2.5-coder:7b \
    || echo "WARN: model pull failed — run manually: ollama pull <model>"

# ── 5. Start exo node ─────────────────────────────────────────────────────────
echo "[5/6] Starting exo inference node (priority=${EXO_PRIORITY})..."
systemctl enable --now exo-node.service

# ── 6. Configure SSH + report ─────────────────────────────────────────────────
echo "[6/6] Starting SSH..."
systemctl enable --now ssh

echo "Node ready."
echo ""
echo "  Hostname : ${NODE_HOSTNAME}"
echo "  GPU      : ${GPU_MODEL} (${GPU_VRAM_GB} GB VRAM)"
IP=$(hostname -I | awk '{print $1}')
echo "  IP       : ${IP}"
echo "  Ollama   : http://${IP}:${OLLAMA_PORT}"
echo "  exo      : enabled via exo-node.service"
echo "  SSH      : ssh root@${IP}   (password: llmnode)"
echo ""
echo "  Add to your Cline / Ollama cluster:"
echo "    Base URL: http://${IP}:${OLLAMA_PORT}"
echo ""
echo "  Full log: /var/log/llm-node-setup.log"
echo ""

# Write status file for node-status command
cat > /var/run/llm-node-status << EOF
READY=1
IP=${IP}
OLLAMA_PORT=${OLLAMA_PORT}
GPU=${GPU_MODEL}
VRAM=${GPU_VRAM_GB}
SETUP_TIME=$(date)
EOF

# Mark setup done so the one-shot service doesn't re-run
touch /var/lib/llm-node-setup-done
