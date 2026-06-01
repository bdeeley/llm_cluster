#!/usr/bin/env bash
# =============================================================================
# /opt/node-setup.sh
# Runs once on first boot (via llm-node-setup.service).
# Builds the NVIDIA kernel module (DKMS) and starts inference services.
# =============================================================================
set -euo pipefail

LOG="/var/log/llm-node-setup.log"
exec > >(tee -a "$LOG") 2>&1

source /etc/llm-node.conf

echo "=========================================="
echo " LLM Node Setup — $(date)"
echo " Host: ${NODE_HOSTNAME}  GPU: ${GPU_MODEL}"
echo "=========================================="

# ── 1. Build NVIDIA kernel module ────────────────────────────────────────────
echo "[1/6] Building NVIDIA kernel module via DKMS..."
KVER=$(uname -r)
if ! lsmod | grep -q nvidia; then
    # Ensure matching headers are installed when available
    if ! dpkg -s "linux-headers-$KVER" >/dev/null 2>&1; then
        if apt-cache show "linux-headers-$KVER" >/dev/null 2>&1; then
            echo "Installing linux-headers-$KVER to allow DKMS to build"
            apt-get update
            apt-get install -y --no-install-recommends "linux-headers-$KVER" || true
        else
            echo "linux-headers-$KVER not available via apt; DKMS may fail"
        fi
    fi

    # Try to unload nouveau first to give NVIDIA driver access to the device
    if lsmod | grep -q nouveau; then
        echo "Attempting to unload nouveau modules"
        for m in nouveau nvidia_drm nvidia_modeset drm_kms_helper; do
            modprobe -r "$m" 2>/dev/null || true
        done
    fi

    echo "Running dkms autoinstall -k $KVER (logging to /var/log/dkms-autoinstall.log)"
    if dkms autoinstall -k "$KVER" > /var/log/dkms-autoinstall.log 2>&1; then
        echo "dkms autoinstall succeeded"
    else
        echo "ERROR: dkms autoinstall failed; see /var/log/dkms-autoinstall.log"
    fi

    if ! modprobe nvidia >/dev/null 2>&1; then
        echo "WARN: modprobe nvidia failed — will retry after reboot"
        echo "Recent dmesg (last 50 lines):"
        dmesg | tail -n 50 || true
    fi
    modprobe nvidia_uvm || true
    modprobe nvidia_drm || true
fi
nvidia-smi && echo "NVIDIA driver OK" || echo "WARN: nvidia-smi failed"

# Ensure OpenCL ICD vendor file exists so userspace tools find the NVIDIA ICD
if [[ ! -d /etc/OpenCL/vendors ]]; then
    mkdir -p /etc/OpenCL/vendors
fi
if [[ ! -f /etc/OpenCL/vendors/nvidia.icd ]]; then
    libpath=$(find /usr -name 'libnvidia-opencl.so*' 2>/dev/null | head -n1 || true)
    if [[ -n "$libpath" ]]; then
        printf '%s
' "$libpath" > /etc/OpenCL/vendors/nvidia.icd || true
        echo "Wrote /etc/OpenCL/vendors/nvidia.icd -> $libpath"
    fi
fi

# ── 2. Install exo + torch (needs live CUDA; too large to bundle in ISO) ─────
echo "[2/6] Installing exo distributed inference (this may take a few minutes)..."
if [[ ! -f /opt/exo-env/bin/exo ]]; then
    # Try PyPI first, fall back to GitHub source
    /opt/exo-env/bin/pip install --quiet exo-explore 2>/dev/null \
        || /opt/exo-env/bin/pip install --quiet \
               "git+https://github.com/exo-explore/exo.git" 2>/dev/null \
        || echo "WARN: exo install failed — distributed inference unavailable"
fi
# Install PyTorch with CUDA support (needed by exo)
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
Environment="OLLAMA_NUM_GPU=1"
EOF
systemctl daemon-reload
systemctl enable --now ollama

# ── 4. Pull a starter model ───────────────────────────────────────────────────
echo "[4/6] Pulling starter model (qwen2.5-coder:7b)..."
ollama pull qwen2.5-coder:7b || echo "WARN: model pull failed — check network"

# ── 5. Start exo node ─────────────────────────────────────────────────────────
echo "[5/6] Starting exo inference node (priority=${EXO_PRIORITY})..."
systemctl enable --now exo-node.service

# ── 6. Report status ──────────────────────────────────────────────────────────
echo "[6/6] Node ready."
echo ""
echo "  Hostname : ${NODE_HOSTNAME}"
echo "  GPU      : ${GPU_MODEL} (${GPU_VRAM_GB} GB VRAM)"
IP=$(hostname -I | awk '{print $1}')
echo "  IP       : ${IP}"
echo "  Ollama   : http://${IP}:${OLLAMA_PORT}"
echo "  SSH      : ssh root@${IP}  (password: llmnode)"
echo ""
echo "  Add to your local Ollama load-balancer:"
echo "    OLLAMA_NODES=http://${IP}:${OLLAMA_PORT}"
echo ""
echo "  Setup complete. See /var/log/llm-node-setup.log for details."

# Write a status file that node-status.sh reads
cat > /run/llm-node-ready << EOF
READY=1
IP=${IP}
HOSTNAME=${NODE_HOSTNAME}
GPU=${GPU_MODEL}
OLLAMA=http://${IP}:${OLLAMA_PORT}
EOF
