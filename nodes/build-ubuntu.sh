#!/usr/bin/env bash
# =============================================================================
# build-ubuntu.sh — Build Ubuntu 24.04-based LLM inference node live ISOs
#
# Key improvement over build.sh (Debian):
#   Uses nvidia-driver-550-open which ships PRE-COMPILED kernel modules for
#   Ubuntu's default kernel. No DKMS compilation happens at first boot.
#   Eliminates the main cause of freezes on new hardware (RTX 40xx etc).
#
# Usage:  sudo bash nodes/build-ubuntu.sh [node-a|node-b|all]
#
# Produces:
#   ubuntu-llm-node-a.iso  (RTX 3090 / 5800X3D)
#   ubuntu-llm-node-b.iso  (RTX 4070 / next-gen CPU)
#
# Requirements:
#   sudo apt-get install -y squashfs-tools xorriso wget
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="/tmp/ubuntu-iso-build"

# Ubuntu 24.04.2 LTS Desktop — has single casper/filesystem.squashfs
# that works exactly like Debian live. Ships kernel 6.8.
UBUNTU_ISO_URL="https://releases.ubuntu.com/24.04.2/ubuntu-24.04.2-desktop-amd64.iso"
UBUNTU_ISO_CACHE="${WORK_DIR}/ubuntu-24.04-base.iso"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash build-ubuntu.sh"
for cmd in unsquashfs mksquashfs xorriso wget; do
    command -v "$cmd" &>/dev/null || \
        error "Missing: $cmd  (sudo apt-get install squashfs-tools xorriso wget)"
done

mkdir -p "$WORK_DIR"
TARGET_NODE="${1:-all}"

# ── Download base ISO ─────────────────────────────────────────────────────────
if [[ ! -f "$UBUNTU_ISO_CACHE" ]]; then
    info "Downloading Ubuntu 24.04.2 Desktop ISO (~6 GB)..."
    wget --show-progress -O "$UBUNTU_ISO_CACHE" "$UBUNTU_ISO_URL" || \
        error "Download failed. Check URL or download manually to ${UBUNTU_ISO_CACHE}"
else
    info "Using cached ISO: ${UBUNTU_ISO_CACHE}"
fi

# ── Build one ISO per node config ─────────────────────────────────────────────
build_iso() {
    local CONF="$1"
    source "$CONF"

    local ISO_OUT_NAME="ubuntu-llm-${NODE_NAME}.iso"

    info "============================================================"
    info "Building Ubuntu ISO for ${NODE_HOSTNAME} (${GPU_MODEL})"
    info "============================================================"

    if [[ -f "${SCRIPT_DIR}/${ISO_OUT_NAME}" ]]; then
        info "Skipping — ${ISO_OUT_NAME} already exists (delete to rebuild)"
        return 0
    fi

    local BUILD="${WORK_DIR}/${NODE_NAME}-ubuntu"
    local ISO_MOUNT="${BUILD}/iso-mount"
    local ISO_RW="${BUILD}/iso-rw"
    local SQUASH_RW="${BUILD}/squash-rw"

    rm -rf "$BUILD"
    mkdir -p "$ISO_MOUNT" "$ISO_RW" "$SQUASH_RW"

    # Mount base ISO
    info "Mounting base ISO..."
    mount -o loop,ro "$UBUNTU_ISO_CACHE" "$ISO_MOUNT"
    trap "umount -lf $ISO_MOUNT 2>/dev/null || true" EXIT

    cp -rT "$ISO_MOUNT" "$ISO_RW"
    chmod -R u+w "$ISO_RW"

    # Ubuntu 24.04 uses layered squashfs (no single filesystem.squashfs).
    # Layers in /casper/: minimal.squashfs → minimal.standard.squashfs →
    #                      minimal.standard.live.squashfs
    # We merge all layers into one rootfs, modify it, repack as minimal.squashfs,
    # and remove the other layer files so casper only sees our single squashfs.
    info "Extracting and merging layered squashfs (~10 min)..."
    local layers_found=0
    for sq in minimal.squashfs minimal.standard.squashfs minimal.standard.live.squashfs; do
        if [[ -f "${ISO_MOUNT}/casper/${sq}" ]]; then
            info "  Merging layer: ${sq}"
            unsquashfs -f -d "$SQUASH_RW" "${ISO_MOUNT}/casper/${sq}"
            layers_found=$((layers_found + 1))
        fi
    done
    # Fallback: old-style single squashfs (Ubuntu 22.04 and earlier)
    if [[ $layers_found -eq 0 ]]; then
        if [[ -f "${ISO_MOUNT}/casper/filesystem.squashfs" ]]; then
            info "  Using legacy filesystem.squashfs"
            unsquashfs -d "$SQUASH_RW" "${ISO_MOUNT}/casper/filesystem.squashfs"
        else
            error "No squashfs found in ISO casper/ directory"
        fi
    fi

    # Bind mounts for chroot
    for mp in proc sys dev dev/pts; do
        mount --bind "/$mp" "${SQUASH_RW}/$mp"
    done
    trap "for mp in dev/pts dev sys proc; do umount -lf ${SQUASH_RW}/\$mp 2>/dev/null||true; done; umount -lf $ISO_MOUNT 2>/dev/null||true" EXIT

    # Copy overlay files
    info "Copying overlay files..."
    cp -r "${SCRIPT_DIR}/overlay/"* "$SQUASH_RW/"

    # Install Ubuntu version of node-setup if it exists
    if [[ -f "${SCRIPT_DIR}/overlay-ubuntu/opt/node-setup.sh" ]]; then
        mkdir -p "${SQUASH_RW}/opt"
        cp "${SCRIPT_DIR}/overlay-ubuntu/opt/node-setup.sh" "${SQUASH_RW}/opt/node-setup.sh"
        chmod +x "${SQUASH_RW}/opt/node-setup.sh"
    fi

    # Write node config
    cat > "${SQUASH_RW}/etc/llm-node.conf" << EOF
NODE_NAME=${NODE_NAME}
NODE_HOSTNAME=${NODE_HOSTNAME}
GPU_MODEL=${GPU_MODEL}
GPU_VRAM_GB=${GPU_VRAM_GB}
NVIDIA_DRIVER_BRANCH=${NVIDIA_DRIVER_BRANCH}
OLLAMA_PORT=${OLLAMA_PORT}
EXO_PRIORITY=${EXO_PRIORITY}
EOF

    cp /etc/resolv.conf "${SQUASH_RW}/etc/resolv.conf"

    # Chroot: install packages
    info "Installing packages in chroot (nvidia-open, ollama, etc.)..."
    chroot "$SQUASH_RW" /bin/bash << CHROOT
set -e
export DEBIAN_FRONTEND=noninteractive

# Ubuntu 24.04 repos with universe (needed for some packages)
cat > /etc/apt/sources.list << 'EOF'
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF
rm -f /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true

apt-get update -qq

# Remove GNOME desktop to slim down the squashfs
apt-get purge -y --auto-remove \
    ubuntu-desktop gnome-shell gnome-session \
    thunderbird libreoffice* snapd \
    2>/dev/null || true

# Core server packages
apt-get install -y --no-install-recommends \
    openssh-server curl wget git \
    python3 python3-pip python3-venv \
    net-tools iproute2 htop nvtop jq \
    pciutils usbutils lshw ubuntu-drivers-common \
    linux-headers-generic build-essential

# ── NVIDIA: pre-compiled open kernel modules (NO DKMS at first boot) ─────────
# nvidia-driver-550-open ships pre-built .ko files for Ubuntu's kernel.
# On first boot, just modprobe — no compilation needed.
apt-get install -y --no-install-recommends \
    nvidia-driver-550-open \
    nvidia-utils-550 \
    libnvidia-compute-550

# Optional toolkit for on-node debugging/build work. The runtime path for the
# live exo node only needs the driver/runtime stack, not a version-pinned toolkit.
apt-get install -y --no-install-recommends nvidia-cuda-toolkit 2>/dev/null || true

# Ollama
curl -fsSL https://ollama.com/install.sh | sh

# Create Python venv for exo install on first boot
python3 -m venv /opt/exo-env
/opt/exo-env/bin/pip install --quiet --upgrade pip

# Enable services
systemctl enable ssh
systemctl enable ollama-node.service
systemctl enable llm-node-setup.service

# SSH: allow root login
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config
echo "root:llmnode" | chpasswd

# Disable auto-upgrade prompts and apt timers that slow first boot
systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true

# Disable GNOME display manager if it survived the purge
systemctl disable gdm3 2>/dev/null || true

# Set default target to multi-user (no graphical)
systemctl set-default multi-user.target

CHROOT

    # Set hostname
    echo "$NODE_HOSTNAME" > "${SQUASH_RW}/etc/hostname"
    cat > "${SQUASH_RW}/etc/hosts" << EOF
127.0.0.1   localhost
127.0.1.1   ${NODE_HOSTNAME}
EOF

    # Unmount chroot binds before repacking
    info "Unmounting chroot bind mounts..."
    for mp in dev/pts dev sys proc; do
        umount -lf "${SQUASH_RW}/$mp" 2>/dev/null || true
    done
    umount -lf "$ISO_MOUNT" 2>/dev/null || true
    trap - EXIT

    # Repack squashfs — output as minimal.squashfs (Ubuntu 24.04 primary layer name)
    # Remove all other layer files so casper only loads our single merged squashfs.
    info "Repacking squashfs (~10 min)..."
    rm -f "${ISO_RW}/casper/minimal.squashfs" \
          "${ISO_RW}/casper/minimal.standard.squashfs" \
          "${ISO_RW}/casper/minimal.standard.live.squashfs" \
          "${ISO_RW}/casper/filesystem.squashfs"
    mksquashfs "$SQUASH_RW" "${ISO_RW}/casper/minimal.squashfs" \
        -comp xz -b 1M -noappend -no-progress \
        -e "${SQUASH_RW}/proc" \
        -e "${SQUASH_RW}/sys" \
        -e "${SQUASH_RW}/dev"

    # Remove stale layer squashfs/size/manifest/gpg files, keep only our merged one
    for sq_prefix in minimal.standard minimal.standard.live \
                     minimal.de minimal.en minimal.es minimal.fr minimal.it \
                     minimal.no-languages minimal.pt minimal.ru minimal.zh \
                     minimal.enhanced-secureboot minimal.standard.enhanced-secureboot \
                     minimal.standard.de minimal.standard.en minimal.standard.es \
                     minimal.standard.fr minimal.standard.it minimal.standard.no-languages \
                     minimal.standard.pt minimal.standard.ru minimal.standard.zh; do
        rm -f "${ISO_RW}/casper/${sq_prefix}."* 2>/dev/null || true
    done

    # Update size and manifest for our single squashfs
    printf '%s' "$(du -sx --block-size=1 "$SQUASH_RW" | cut -f1)" \
        > "${ISO_RW}/casper/minimal.size"
    rm -f "${ISO_RW}/casper/filesystem.size" "${ISO_RW}/casper/filesystem.manifest"
    chroot "$SQUASH_RW" dpkg-query -W --showformat='${Package} ${Version}\n' \
        > "${ISO_RW}/casper/minimal.manifest" 2>/dev/null || true

    rm -rf "$SQUASH_RW"

    # Rebuild ISO with hybrid boot (BIOS + UEFI)
    # Ubuntu 24.04: EFI files are in EFI/boot/ directly (no separate efi.img).
    info "Building final ISO: ${ISO_OUT_NAME}"

    local MBR_BIN="${WORK_DIR}/isohdpfx.bin"
    dd if="$UBUNTU_ISO_CACHE" bs=1 count=432 of="$MBR_BIN" 2>/dev/null

    xorriso -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "LLM-${NODE_HOSTNAME^^}" \
        --protective-msdos-label \
        -partition_offset 16 \
        --grub2-mbr "$MBR_BIN" \
        -c '/boot.catalog' \
        -b '/boot/grub/i386-pc/eltorito.img' \
            -no-emul-boot -boot-load-size 4 -boot-info-table \
            --grub2-boot-info \
        -eltorito-alt-boot \
        -e '/EFI/boot/bootx64.efi' \
            -no-emul-boot \
        -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b \
            "${ISO_RW}/EFI/boot/bootx64.efi" \
        -appended_part_as_gpt \
        -o "${SCRIPT_DIR}/${ISO_OUT_NAME}" \
        "$ISO_RW" 2>&1 | tail -5

    info "Done: ${SCRIPT_DIR}/${ISO_OUT_NAME}"
    ls -lh "${SCRIPT_DIR}/${ISO_OUT_NAME}"
}

case "$TARGET_NODE" in
    node-a)
        build_iso "${SCRIPT_DIR}/node-a.conf"
        ;;
    node-b)
        build_iso "${SCRIPT_DIR}/node-b.conf"
        ;;
    all)
        build_iso "${SCRIPT_DIR}/node-a.conf"
        build_iso "${SCRIPT_DIR}/node-b.conf"
        ;;
    *)
        error "Unknown target '${TARGET_NODE}'. Use: node-a, node-b, or all"
        ;;
esac

info "All ISOs built."
info "Flash with:"
info "  sudo dd if=ubuntu-llm-node-a.iso of=/dev/sdX bs=4M status=progress && sync"
