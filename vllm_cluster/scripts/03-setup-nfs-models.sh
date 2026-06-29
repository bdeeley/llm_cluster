#!/bin/bash
# 03-setup-nfs-models.sh
#
# Set up NFS server on maxpower to share /NVME/MODELS with theplague
# This ensures both nodes use the same model cache

set -e

WORKER_HOST="bdeeley@theplague.deeleymotorsports.lan"
MAXPOWER_IP="172.16.0.28"
MODELS_PATH="/NVME/MODELS"

echo "=========================================="
echo "Setting up NFS Model Sharing"
echo "=========================================="
echo ""

# Step 1: Setup NFS server on maxpower
echo "Step 1️⃣  : Setting up NFS server on maxpower..."

# Check if NFS is installed
if ! dpkg -l | grep -q nfs-kernel-server; then
    echo "  Installing NFS server..."
    sudo apt-get update > /dev/null
    sudo apt-get install -y nfs-kernel-server > /dev/null 2>&1
fi

# Create /etc/exports entry
if ! grep -q "$MODELS_PATH" /etc/exports 2>/dev/null; then
    echo "  Adding $MODELS_PATH to /etc/exports..."
    echo "$MODELS_PATH *(rw,sync,no_subtree_check,no_root_squash)" | sudo tee -a /etc/exports > /dev/null
else
    echo "  $MODELS_PATH already in /etc/exports"
fi

# Export NFS
sudo exportfs -a
sudo systemctl restart nfs-kernel-server

echo "  ✓ NFS server configured"
echo ""

# Step 2: Setup NFS client on theplague
echo "Step 2️⃣  : Setting up NFS client on theplague..."

ssh $WORKER_HOST << EOFNFS
set -e

echo "  Installing NFS client..."
sudo apt-get update > /dev/null 2>&1 || true
sudo apt-get install -y nfs-common > /dev/null 2>&1 || true

echo "  Creating mount point..."
sudo mkdir -p /NVME/MODELS 2>/dev/null || true

# Try to mount NFS
if ! mountpoint -q /NVME/MODELS; then
    echo "  Mounting $MAXPOWER_IP:$MODELS_PATH..."
    sudo mount -t nfs $MAXPOWER_IP:$MODELS_PATH /NVME/MODELS 2>/dev/null || {
        echo "  ⚠️  NFS mount failed, falling back to local directory"
        true
    }
fi

# Verify mount
if mountpoint -q /NVME/MODELS; then
    echo "  ✓ NFS mounted at /NVME/MODELS"
else
    echo "  ⚠️  Using local /NVME/MODELS (not NFS mounted)"
fi

# Make it permanent in fstab
if ! grep -q "$MAXPOWER_IP:$MODELS_PATH" /etc/fstab 2>/dev/null; then
    echo "  Adding to /etc/fstab..."
    echo "$MAXPOWER_IP:$MODELS_PATH /NVME/MODELS nfs rw,sync,hard,intr,_netdev 0 0" | sudo tee -a /etc/fstab > /dev/null || true
fi

EOFNFS

echo "  ✓ NFS client configured on theplague"
echo ""

echo "✅ NFS setup complete"
echo ""
echo "Model sharing:"
echo "  maxpower: $MODELS_PATH (NFS server)"
echo "  theplague: /NVME/MODELS (NFS client)"
echo ""
echo "Next: Models downloaded to maxpower will be visible on theplague"
