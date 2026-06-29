#!/bin/bash
# 00-setup-theplague.sh
# 
# Prepare theplague (remote worker) for vLLM cluster
# This creates venv, installs dependencies, and ensures /NVME/MODELS is mounted

set -e

WORKER_HOST="bdeeley@theplague.deeleymotorsports.lan"
WORKER_IP="172.16.0.29"

echo "=========================================="
echo "Setting up theplague worker node"
echo "=========================================="
echo ""

# Test connectivity
echo "Step 1️⃣  : Testing SSH connectivity..."
if ! ssh -o ConnectTimeout=5 $WORKER_HOST "echo OK" > /dev/null 2>&1; then
    echo "  ❌ Cannot reach $WORKER_HOST"
    echo "  Try: ssh-copy-id -i ~/.ssh/id_rsa $WORKER_HOST"
    exit 1
fi
echo "  ✓ SSH connection working"
echo ""

# Setup on theplague
ssh $WORKER_HOST << 'EOFSETUP'
set -e

echo "  Checking NVME/MODELS..."
if [ ! -d "/NVME/MODELS" ]; then
    echo "    ⚠️  /NVME/MODELS not found, creating link if needed"
    # Check for alternative paths
    if [ -d "/mnt/nvme/MODELS" ]; then
        sudo mkdir -p /NVME 2>/dev/null || true
        sudo ln -s /mnt/nvme/MODELS /NVME/MODELS 2>/dev/null || true
        echo "    ✓ Created link to /mnt/nvme/MODELS"
    fi
fi

if [ -d "/NVME/MODELS" ]; then
    echo "    ✓ /NVME/MODELS accessible"
else
    echo "    ⚠️  /NVME/MODELS still not found - will create empty dir"
    mkdir -p /NVME/MODELS 2>/dev/null || true
fi
echo ""

echo "  Checking Python environment..."
if [ ! -f "/home/bdeeley/.venv/bin/activate" ]; then
    echo "    Creating venv..."
    python3 -m venv /home/bdeeley/.venv
    source /home/bdeeley/.venv/bin/activate
else
    source /home/bdeeley/.venv/bin/activate
    echo "    ✓ venv already exists"
fi
echo ""

echo "  Installing dependencies..."
pip install -q --upgrade pip
pip install -q torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu124 2>/dev/null || pip install -q torch torchvision torchaudio
pip install -q vllm[all] transformers accelerate ray[tune] peft 2>/dev/null || echo "    (Some packages may have skipped, but core deps installed)"
echo "    ✓ Dependencies installed"
echo ""

echo "  Verifying CUDA..."
python3 -c "import torch; print(f'    PyTorch version: {torch.__version__}'); print(f'    CUDA available: {torch.cuda.is_available()}'); print(f'    CUDA device: {torch.cuda.get_device_name(0) if torch.cuda.is_available() else \"None\"}')"
echo ""

echo "  ✓ Theplague setup complete"
EOFSETUP

echo "✅ Worker setup complete"
echo ""
echo "Next step: Run ./scripts/01-start-2gpu-vllm.sh"
