#!/usr/bin/env bash
# =============================================================================
# build.sh — Build two Debian live ISOs for LLM inference nodes
#
# Usage:  sudo bash /path/to/nodes/build.sh
#
# Produces:
#   debian-llm-node-a.iso  (RTX 3090 / 5800X3D)
#   debian-llm-node-b.iso  (RTX 4070 / next-gen CPU)
#
# Requirements (on the build machine):
#   sudo apt-get install -y squashfs-tools xorriso wget
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="/tmp/llm-iso-build"
DEBIAN_LIVE_URL="https://cdimage.debian.org/cdimage/unofficial/non-free/cd-including-firmware/current-live/amd64/iso-hybrid/debian-live-13-amd64-standard+nonfree.iso"
DEBIAN_ISO_CACHE="${WORK_DIR}/debian-live-base.iso"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Preflight checks ──────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run as root: sudo bash build.sh"
for cmd in unsquashfs mksquashfs xorriso wget; do
    command -v "$cmd" &>/dev/null || error "Missing: $cmd  (sudo apt-get install squashfs-tools xorriso wget)"
done

mkdir -p "$WORK_DIR"

# ── Download base ISO ─────────────────────────────────────────────────────────
if [[ ! -f "$DEBIAN_ISO_CACHE" ]]; then
    info "Downloading Debian live non-free ISO (~1.5 GB)..."
    wget -O "$DEBIAN_ISO_CACHE" "$DEBIAN_LIVE_URL" || \
        error "Download failed. Check URL or download manually to ${DEBIAN_ISO_CACHE}"
else
    info "Using cached ISO: ${DEBIAN_ISO_CACHE}"
fi

# ── Build one ISO per node config ─────────────────────────────────────────────
build_iso() {
    local CONF="$1"
    source "$CONF"   # loads NODE_NAME, NODE_HOSTNAME, GPU_MODEL, etc.

    info "============================================================"
    info "Building ISO for ${NODE_HOSTNAME} (${GPU_MODEL})"
    info "============================================================"

    if [[ -f "${SCRIPT_DIR}/${ISO_OUT}" ]]; then
        info "Skipping — ${ISO_OUT} already exists (delete it to rebuild)"
        return 0
    fi

    local BUILD="${WORK_DIR}/${NODE_NAME}"
    local ISO_MOUNT="${BUILD}/iso-mount"
    local ISO_RW="${BUILD}/iso-rw"
    local SQUASH_RW="${BUILD}/squash-rw"

    rm -rf "$BUILD"
    mkdir -p "$ISO_MOUNT" "$ISO_RW" "$SQUASH_RW"

    # Mount base ISO
    info "Mounting base ISO..."
    mount -o loop,ro "$DEBIAN_ISO_CACHE" "$ISO_MOUNT"
    trap "umount -lf $ISO_MOUNT 2>/dev/null || true" EXIT

    cp -rT "$ISO_MOUNT" "$ISO_RW"
    chmod -R u+w "$ISO_RW"

    # Extract squashfs
    info "Extracting root filesystem (this takes a few minutes)..."
    unsquashfs -d "$SQUASH_RW" "${ISO_MOUNT}/live/filesystem.squashfs"

    # ── Bind mounts for chroot ────────────────────────────────────────────────
    for mp in proc sys dev dev/pts; do
        mount --bind "/$mp" "${SQUASH_RW}/$mp"
    done
    trap "for mp in dev/pts dev sys proc; do umount -lf ${SQUASH_RW}/\$mp 2>/dev/null || true; done; umount -lf $ISO_MOUNT 2>/dev/null || true" EXIT

    # ── Copy overlay files into squashfs ─────────────────────────────────────
    info "Copying overlay files..."
    cp -r "${SCRIPT_DIR}/overlay/"* "$SQUASH_RW/"

    # Write node-specific config
    cat > "${SQUASH_RW}/etc/llm-node.conf" << EOF
NODE_NAME=${NODE_NAME}
NODE_HOSTNAME=${NODE_HOSTNAME}
GPU_MODEL=${GPU_MODEL}
GPU_VRAM_GB=${GPU_VRAM_GB}
NVIDIA_DRIVER_BRANCH=${NVIDIA_DRIVER_BRANCH}
OLLAMA_PORT=${OLLAMA_PORT}
EXO_PRIORITY=${EXO_PRIORITY}
EOF

    # ── DNS for chroot ────────────────────────────────────────────────────────
    cp /etc/resolv.conf "${SQUASH_RW}/etc/resolv.conf"

    # ── Chroot: install packages ──────────────────────────────────────────────
    info "Installing packages in chroot (NVIDIA driver, Ollama, Python)..."
    chroot "$SQUASH_RW" /bin/bash << 'CHROOT'
set -e
export DEBIAN_FRONTEND=noninteractive

# Write clean apt sources — live-ISO local repos are invalid during chroot build
source /etc/os-release
SUITE=${VERSION_CODENAME:-stable}
cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian ${SUITE} main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${SUITE}-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${SUITE}-updates main contrib non-free non-free-firmware
EOF
# Remove any sources.list.d entries that reference live media or cdrom
find /etc/apt/sources.list.d/ -name '*.list' \
    -exec grep -qlE 'file:/run/live|cdrom:' {} \; \
    -delete 2>/dev/null || true

apt-get update -qq

# Core tools
apt-get install -y --no-install-recommends \
    openssh-server curl wget git python3 python3-pip python3-venv \
    net-tools iproute2 htop nvtop jq pciutils usbutils

# NVIDIA driver + DKMS (kernel module built at first boot by the setup service)
apt-get install -y --no-install-recommends \
    nvidia-driver firmware-misc-nonfree \
    linux-headers-amd64

# Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Create Python venv for exo — packages installed on first boot
# (torch is multi-GB and needs live CUDA; exo-explore needs Python compat check)
python3 -m venv /opt/exo-env
/opt/exo-env/bin/pip install --quiet --upgrade pip

# Enable services
systemctl enable ssh
systemctl enable ollama-node.service
systemctl enable llm-node-setup.service

# SSH: allow root login with password for initial setup
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
echo "root:llmnode" | chpasswd

CHROOT

    # ── Set hostname ──────────────────────────────────────────────────────────
    echo "$NODE_HOSTNAME" > "${SQUASH_RW}/etc/hostname"
    cat > "${SQUASH_RW}/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   ${NODE_HOSTNAME}
EOF

    # ── Unmount chroot binds BEFORE repacking ─────────────────────────────────
    # Must happen here — mksquashfs will pack live /proc files if still mounted
    info "Unmounting chroot bind mounts..."
    for mp in dev/pts dev sys proc; do
        umount -lf "${SQUASH_RW}/$mp" 2>/dev/null || true
    done
    umount -lf "$ISO_MOUNT" 2>/dev/null || true
    trap - EXIT

    # ── Repack squashfs ───────────────────────────────────────────────────────
    info "Repacking squashfs (this takes several minutes)..."
    rm -f "${ISO_RW}/live/filesystem.squashfs"
    mksquashfs "$SQUASH_RW" "${ISO_RW}/live/filesystem.squashfs" \
        -comp xz -b 1M -noappend -no-progress \
        -e "${SQUASH_RW}/proc" \
        -e "${SQUASH_RW}/sys" \
        -e "${SQUASH_RW}/dev"

    # Update filesystem.size
    printf '%s' "$(du -sx --block-size=1 "$SQUASH_RW" | cut -f1)" \
        > "${ISO_RW}/live/filesystem.size"

    # Free disk space — squash-rw is now compressed into the squashfs
    rm -rf "$SQUASH_RW"

    # ── Rebuild ISO ───────────────────────────────────────────────────────────
    info "Building final ISO: ${ISO_OUT}"

    # Extract hybrid MBR from the source ISO (first 432 bytes) — more reliable
    # than depending on the isolinux host package providing isohdpfx.bin
    local MBR_BIN="${WORK_DIR}/isohdpfx.bin"
    dd if="$DEBIAN_ISO_CACHE" bs=1 count=432 of="$MBR_BIN" 2>/dev/null

    xorriso -as mkisofs \
        -iso-level 3 \
        -o "${SCRIPT_DIR}/${ISO_OUT}" \
        -isohybrid-mbr "$MBR_BIN" \
        -c isolinux/boot.cat \
        -b isolinux/isolinux.bin \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        "${ISO_RW}"

    info "ISO ready: ${SCRIPT_DIR}/${ISO_OUT}"
    info "Flash with:  sudo dd if=${ISO_OUT} of=/dev/sdX bs=4M status=progress && sync"

    # Free disk space — iso-rw is now packed into the ISO file
    rm -rf "$ISO_RW" "$ISO_MOUNT"
}

# ── Build both nodes ──────────────────────────────────────────────────────────
build_iso "${SCRIPT_DIR}/node-a.conf"
build_iso "${SCRIPT_DIR}/node-b.conf"

info ""
info "All done! Two ISOs built:"
info "  ${SCRIPT_DIR}/debian-llm-node-a.iso  →  USB stick for RTX 3090 machine"
info "  ${SCRIPT_DIR}/debian-llm-node-b.iso  →  USB stick for RTX 4070 machine"
