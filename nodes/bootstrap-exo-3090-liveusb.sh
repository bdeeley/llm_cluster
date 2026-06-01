#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NODE_NAME=${NODE_NAME:-debian}
NODE_USER=${NODE_USER:-bdeeley}
PERSIST_ROOT=${PERSIST_ROOT:-/NVME/live-bootstrap/${NODE_NAME}}
EXO_ROOT=${EXO_ROOT:-/NVME/exo-node-3090}
EXO_HOME=${EXO_HOME:-/home/${NODE_USER}/exo}
EXO_REPO_DIR=${EXO_REPO_DIR:-${EXO_ROOT}/exo}
EXO_REPO_SOURCE=${EXO_REPO_SOURCE:-/BIGMIRROR/exo}
EXO_GIT_URL=${EXO_GIT_URL:-https://github.com/exo-explore/exo.git}
MODEL_DIR=${MODEL_DIR:-/BIGMIRROR/exo-models-debian}
LOG_FILE=${LOG_FILE:-/BIGMIRROR/exo-remotes.log}
EVENT_LOG_DIR=${EVENT_LOG_DIR:-${EXO_ROOT}/event_log-3090}
XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-${EXO_ROOT}/config}
XDG_DATA_HOME=${XDG_DATA_HOME:-${EXO_ROOT}/data}
XDG_CACHE_HOME=${XDG_CACHE_HOME:-${EXO_ROOT}/cache}
SERVICE_NAME=${SERVICE_NAME:-exo-remote-3090.service}
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
LAUNCHER=${LAUNCHER:-${EXO_ROOT}/bin/go}
OVERRIDE_MEMORY_MB=${OVERRIDE_MEMORY_MB:-24000}
API_PORT=${API_PORT:-52415}
LIBP2P_PORT=${LIBP2P_PORT:-5679}
BOOTSTRAP_PEERS=${BOOTSTRAP_PEERS:-/ip4/172.16.0.174/tcp/5678,/ip4/172.16.0.174/tcp/5680}
CUDA_ROOT=${CUDA_ROOT:-/home/bdeeley/cuda}
KEYPAIR_PATH=${KEYPAIR_PATH:-${XDG_CONFIG_HOME}/exo/node_id-3090.keypair}

if [[ ! -d "${CUDA_ROOT}" ]]; then
    CUDA_ROOT=/usr
fi

log() {
    printf '[exo-3090] %s\n' "$*"
}

run_as_user() {
    local cmd="$1"
    runuser -u "$NODE_USER" -- bash -lc "$cmd"
}

ensure_dir() {
    install -d -m 0755 "$1"
}

ensure_user_dir() {
    run_as_user "mkdir -p '$1'"
}

configure_apt_sources() {
    local suite

    source /etc/os-release
    suite=${VERSION_CODENAME:-stable}

    cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian ${suite} main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${suite}-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${suite}-updates main contrib non-free non-free-firmware
EOF

    find /etc/apt/sources.list.d/ -name '*.list' \
        -exec grep -qlE 'file:/run/live|cdrom:' {} \; \
        -delete 2>/dev/null || true
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    configure_apt_sources
    apt-get update
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        firmware-misc-nonfree \
        git \
        jq \
        linux-headers-amd64 \
        ninja-build \
        nodejs \
        npm \
        nvidia-cuda-toolkit \
        nvidia-driver \
        ocl-icd-libopencl1 \
        nvidia-opencl-icd \
        nvtop \
        pciutils \
        pkg-config \
        python3 \
        python3-dev \
        python3-pip \
        python3-venv \
        rsync \
        tmux \
        usbutils \
        wget \
        btop

    if apt-cache show nvidia-smi >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends nvidia-smi
    fi
}

require_running_kernel_headers() {
    local running_kernel
    local headers_pkg

    running_kernel=$(uname -r)
    headers_pkg="linux-headers-${running_kernel}"

    if dpkg -s "$headers_pkg" >/dev/null 2>&1; then
        return 0
    fi

    if apt-cache show "$headers_pkg" >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends "$headers_pkg"
        return 0
    fi

    log "Missing ${headers_pkg}; running kernel ${running_kernel} cannot build NVIDIA DKMS modules from this live image"
    log "Boot a kernel that matches the installed headers or bake matching NVIDIA support into the live image"
    exit 1
}

ensure_nvidia_loaded() {
    require_running_kernel_headers
    modprobe nvidia || true
    modprobe nvidia_uvm || true
    modprobe nvidia_drm || true

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        log "nvidia-smi is unavailable after package install; NVIDIA userspace tools are not ready on this boot"
        log "Continuing bootstrap; NVIDIA userspace may become available after DKMS rebuild or on next boot"
    fi

    nvidia-smi >/dev/null
}

# Ensure OpenCL ICD vendor file exists if the NVIDIA ICD library is present
if [[ ! -d /etc/OpenCL/vendors ]]; then
    mkdir -p /etc/OpenCL/vendors
fi
if [[ ! -f /etc/OpenCL/vendors/nvidia.icd ]]; then
    libpath=$(find /usr -name 'libnvidia-opencl.so*' 2>/dev/null | head -n1 || true)
    if [[ -n "$libpath" ]]; then
        printf '%s
' "$libpath" > /etc/OpenCL/vendors/nvidia.icd || true
        log "Wrote /etc/OpenCL/vendors/nvidia.icd -> $libpath"
    fi
fi

ensure_user_layout() {
    ensure_user_dir "$EXO_ROOT"
    ensure_user_dir "$EVENT_LOG_DIR"
    ensure_user_dir "$XDG_CONFIG_HOME/exo"
    ensure_user_dir "$XDG_DATA_HOME"
    ensure_user_dir "$XDG_CACHE_HOME"
    ensure_user_dir "$(dirname "$LAUNCHER")"
    ensure_user_dir "$MODEL_DIR"
    ensure_dir "/tmp/exo-logs"

    if [[ -e "$EXO_HOME" && ! -L "$EXO_HOME" ]]; then
        mv "$EXO_HOME" "${EXO_HOME}.bak.$(date +%s)"
    fi
    ln -sfn "$EXO_REPO_DIR" "$EXO_HOME"
    chown -h "$NODE_USER:$NODE_USER" "$EXO_HOME"
}

sync_repo() {
    if [[ -d "$EXO_REPO_SOURCE/.git" ]]; then
        ensure_user_dir "$EXO_REPO_DIR"
        run_as_user "rsync -a --delete \
            --exclude '.git' \
            --exclude '.venv' \
            --exclude 'target' \
            --exclude 'node_modules' \
            '$EXO_REPO_SOURCE/' '$EXO_REPO_DIR/'"
    elif [[ -d "$EXO_REPO_DIR/.git" ]]; then
        run_as_user "cd '$EXO_REPO_DIR' && git fetch --all --tags && git pull --ff-only"
    else
        run_as_user "git clone '$EXO_GIT_URL' '$EXO_REPO_DIR'"
    fi
}

ensure_uv() {
    if [[ ! -x "/home/${NODE_USER}/.local/bin/uv" ]]; then
        run_as_user "curl -LsSf https://astral.sh/uv/install.sh | sh"
    fi
}

ensure_rust() {
    if [[ ! -x "/home/${NODE_USER}/.cargo/bin/rustup" ]]; then
        run_as_user "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
    fi
    run_as_user "source ~/.cargo/env && rustup toolchain install nightly && rustup default nightly"
}

build_dashboard() {
    run_as_user "cd '$EXO_REPO_DIR/dashboard' && npm install && npm run build"
}

sync_python_env() {
    run_as_user "export PATH=\"$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin\" && cd '$EXO_REPO_DIR' && ~/.local/bin/uv sync --extra mlx-cuda12"
}

write_launcher() {
    cat > "$LAUNCHER" << EOF
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE=${LOG_FILE}
MODELS_DIR=${MODEL_DIR}
EVENT_LOG_DIR=${EVENT_LOG_DIR}
XDG_CONFIG_HOME=${XDG_CONFIG_HOME}
XDG_DATA_HOME=${XDG_DATA_HOME}
XDG_CACHE_HOME=${XDG_CACHE_HOME}
KEYPAIR_PATH=${KEYPAIR_PATH}
CUDA_ROOT=${CUDA_ROOT}
OVERRIDE_MEMORY_MB=${OVERRIDE_MEMORY_MB}
API_PORT=${API_PORT}
LIBP2P_PORT=${LIBP2P_PORT}
BOOTSTRAP_PEERS=${BOOTSTRAP_PEERS}

cd ${EXO_HOME}

pgrep -f -- "^/home/${NODE_USER}/\\.local/bin/uv run exo --no-master-candidate --api-port \\${API_PORT} --libp2p-port \\${LIBP2P_PORT}" | xargs -r kill || true
pgrep -f -- "^${EXO_REPO_DIR}/\\.venv/bin/python3 ${EXO_REPO_DIR}/\\.venv/bin/exo --no-master-candidate --api-port \\${API_PORT} --libp2p-port \\${LIBP2P_PORT}" | xargs -r kill || true
pgrep -f -- "^${EXO_REPO_DIR}/\\.venv/bin/python ${EXO_REPO_DIR}/\\.venv/bin/exo --no-master-candidate --api-port \\${API_PORT} --libp2p-port \\${LIBP2P_PORT}" | xargs -r kill || true
rm -f /home/${NODE_USER}/.cache/exo/exo.pid /tmp/exo-worker/exo/exo.pid

mkdir -p "\$(dirname "\$LOG_FILE")" "\$MODELS_DIR" "\$EVENT_LOG_DIR" "\$XDG_CONFIG_HOME/exo" "\$XDG_DATA_HOME" "\$XDG_CACHE_HOME" /tmp/exo-logs

export PATH=/home/${NODE_USER}/.cargo/bin:/home/${NODE_USER}/.local/bin:/usr/local/bin:/usr/bin:/bin
export CUDA_HOME="\$CUDA_ROOT"
export CUDA_PATH="\$CUDA_ROOT"
export CPATH="\$CUDA_ROOT/include:/usr/include"
export CPLUS_INCLUDE_PATH="\$CUDA_ROOT/include:/usr/include"
export BROWSER=/bin/true
export EXO_NODE_ID_KEYPAIR_PATH="\$KEYPAIR_PATH"
export EXO_EVENT_LOG_DIR="\$EVENT_LOG_DIR"
export EXO_DEFAULT_MODELS_DIR="\$MODELS_DIR"
export XDG_CONFIG_HOME
export XDG_DATA_HOME
export XDG_CACHE_HOME
export LD_LIBRARY_PATH="${EXO_REPO_DIR}/.venv/lib/python3.13/site-packages/nvidia/cublas/lib:${EXO_REPO_DIR}/.venv/lib/python3.13/site-packages/nvidia/cuda_nvrtc/lib:${EXO_REPO_DIR}/.venv/lib/python3.13/site-packages/nvidia/cudnn/lib:${EXO_REPO_DIR}/.venv/lib/python3.13/site-packages/nvidia/cufft/lib:${EXO_REPO_DIR}/.venv/lib/python3.13/site-packages/nvidia/nccl/lib:${EXO_REPO_DIR}/.venv/lib/python3.13/site-packages/nvidia/nvjitlink/lib"
export OVERRIDE_MEMORY_MB

echo "===== \$(date -Is) [debian] launcher start =====" >> "\$LOG_FILE"
exec /home/${NODE_USER}/.local/bin/uv run exo --no-master-candidate --api-port "\$API_PORT" --libp2p-port "\$LIBP2P_PORT" --bootstrap-peers "\$BOOTSTRAP_PEERS" >> "\$LOG_FILE" 2>&1
EOF
    chmod +x "$LAUNCHER"
    chown "$NODE_USER:$NODE_USER" "$LAUNCHER" 2>/dev/null || true
}

write_service() {
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=exo remote 3090 follower
After=network-online.target ssh.service
Wants=network-online.target

[Service]
Type=simple
User=${NODE_USER}
WorkingDirectory=${EXO_HOME}
ExecStart=${LAUNCHER}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$SERVICE_NAME"
}

write_state() {
    cat > "$PERSIST_ROOT/exo-3090-state.env" << EOF
EXO_ROOT=${EXO_ROOT}
EXO_REPO_DIR=${EXO_REPO_DIR}
EXO_HOME=${EXO_HOME}
MODEL_DIR=${MODEL_DIR}
LOG_FILE=${LOG_FILE}
EVENT_LOG_DIR=${EVENT_LOG_DIR}
XDG_CONFIG_HOME=${XDG_CONFIG_HOME}
XDG_DATA_HOME=${XDG_DATA_HOME}
XDG_CACHE_HOME=${XDG_CACHE_HOME}
CUDA_ROOT=${CUDA_ROOT}
KEYPAIR_PATH=${KEYPAIR_PATH}
OVERRIDE_MEMORY_MB=${OVERRIDE_MEMORY_MB}
API_PORT=${API_PORT}
LIBP2P_PORT=${LIBP2P_PORT}
BOOTSTRAP_PEERS=${BOOTSTRAP_PEERS}
LAST_BOOTSTRAP=$(date -Is)
EOF
}

if [[ -x "$SCRIPT_DIR/bootstrap-standard-liveusb.sh" ]]; then
    "$SCRIPT_DIR/bootstrap-standard-liveusb.sh"
fi

log "Installing exo node prerequisites"
install_packages
# Prevent nouveau from binding GPUs so NVIDIA can load
blacklist_nouveau() {
    cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    # Only update initramfs on writable systems. Live/read-only systems (like
    # our live USB) will not accept initramfs updates and doing so can
    # encourage an immediate reboot by operators; skip in that case.
    if mountpoint -q /run/live || mountpoint -q /ro || ! [ -w / ]; then
        echo "Running on read-only/live system — skipping update-initramfs."
        echo "Blacklist written to /etc/modprobe.d/blacklist-nouveau.conf;"
        echo "NVIDIA modules will bind after the next real boot."
    else
        update-initramfs -u -k all || true
    fi
}
blacklist_nouveau
ensure_nvidia_loaded
ensure_user_layout
sync_repo
ensure_uv
ensure_rust
build_dashboard
sync_python_env
write_launcher
write_service
write_state

log "exo 3090 bootstrap complete"
log "Manual start: sudo systemctl restart ${SERVICE_NAME}"
log "Manual launcher: sudo -u ${NODE_USER} ${LAUNCHER}"