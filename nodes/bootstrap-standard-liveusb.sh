#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "Run as root" >&2
    exit 1
fi

NODE_NAME=${NODE_NAME:-debian}
NODE_USER=${NODE_USER:-bdeeley}
PERSIST_ROOT=${PERSIST_ROOT:-/NVME/live-bootstrap/${NODE_NAME}}
BIGMIRROR_MOUNT=${BIGMIRROR_MOUNT:-/BIGMIRROR}
NVME_MOUNT=${NVME_MOUNT:-/NVME}
BOOTSTRAP_AUTHORIZED_KEY=${BOOTSTRAP_AUTHORIZED_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII3AFzc9vJSqGTXmFMHIF6IJWNTbvL3Jecw8X4RtTuME bdeeley@maxpower}
PASSWORD_HASH_FILE=${PASSWORD_HASH_FILE:-${PERSIST_ROOT}/shadow-${NODE_USER}.hash}

log() {
    printf '[bootstrap] %s\n' "$*"
}

run_as_user() {
    local cmd="$1"
    runuser -u "$NODE_USER" -- bash -lc "$cmd"
}

require_mountpoint() {
    local mountpoint="$1"
    if ! mountpoint -q "$mountpoint"; then
        echo "Required mountpoint is not mounted: $mountpoint" >&2
        exit 1
    fi
}

ensure_dir() {
    install -d -m 0755 "$1"
}

ensure_user_dir() {
    run_as_user "mkdir -p '$1'"
}

reset_local_apt_cache_dir() {
    mkdir -p /var/cache/apt/archives
    umount /var/cache/apt/archives 2>/dev/null || true
    mkdir -p /var/cache/apt/archives/partial
    chown _apt:root /var/cache/apt/archives/partial 2>/dev/null || true
    chmod 700 /var/cache/apt/archives/partial 2>/dev/null || true
}

persist_root_supports_root_metadata() {
    local probe_dir="$PERSIST_ROOT/.metadata-probe"

    mkdir -p "$probe_dir"
    if chown root:root "$probe_dir" 2>/dev/null; then
        rmdir "$probe_dir" 2>/dev/null || true
        return 0
    fi

    rmdir "$probe_dir" 2>/dev/null || true
    return 1
}

current_mount_source() {
    local mountpoint="$1"
    findmnt -n -o SOURCE --target "$mountpoint" 2>/dev/null || true
}

current_mount_fstype() {
    local mountpoint="$1"
    findmnt -n -o FSTYPE --target "$mountpoint" 2>/dev/null || true
}

current_password_hash() {
    getent shadow "$NODE_USER" | awk -F: '{print $2}'
}

restore_persisted_password_hash() {
    local password_hash

    if [[ ! -s "$PASSWORD_HASH_FILE" ]]; then
        return 0
    fi

    password_hash=$(<"$PASSWORD_HASH_FILE")
    if [[ -n "$password_hash" ]]; then
        usermod -p "$password_hash" "$NODE_USER"
    fi
}

persist_current_password_hash() {
    local password_hash

    password_hash=$(current_password_hash)
    if [[ -z "$password_hash" || "$password_hash" == '!' || "$password_hash" == '*' ]]; then
        return 0
    fi

    ensure_dir "$(dirname "$PASSWORD_HASH_FILE")"
    umask 077
    printf '%s\n' "$password_hash" > "$PASSWORD_HASH_FILE"
}

ensure_fstab_entry() {
    local source="$1"
    local target="$2"
    local fstype="$3"
    local options="$4"
    local dump_pass="$5"
    local entry="${source} ${target} ${fstype} ${options} ${dump_pass}"
    if ! grep -Fqs "$source $target $fstype" /etc/fstab; then
        printf '%s\n' "$entry" >> /etc/fstab
    fi
}

persist_ssh_host_keys() {
    local host_key_dir="$PERSIST_ROOT/ssh-host-keys"
    ensure_dir "$host_key_dir"

    if compgen -G "$host_key_dir/ssh_host_*" > /dev/null; then
        cp "$host_key_dir"/ssh_host_* /etc/ssh/
    else
        cp /etc/ssh/ssh_host_* "$host_key_dir/"
    fi
}

persist_user_ssh() {
    local home_dir="/home/${NODE_USER}"
    local persist_home="$PERSIST_ROOT/home/${NODE_USER}"
    local persist_ssh_dir="$persist_home/.ssh"
    local local_ssh_dir="$home_dir/.ssh"
    local local_authorized_keys="$local_ssh_dir/authorized_keys"

    ensure_dir "$PERSIST_ROOT/home"
    ensure_dir "$persist_home"

    if ! persist_root_supports_root_metadata; then
        chmod 0777 "$PERSIST_ROOT/home" "$persist_home" 2>/dev/null || true
    fi

    if [[ -L "$local_ssh_dir" ]]; then
        rm -f "$local_ssh_dir"
    fi

    install -d -m 0700 -o "$NODE_USER" -g "$NODE_USER" "$local_ssh_dir"

    ensure_user_dir "$persist_ssh_dir"
    run_as_user "chmod 700 '$persist_ssh_dir'" 2>/dev/null || true

    if [[ -z "$(find "$local_ssh_dir" -mindepth 1 -maxdepth 1 2>/dev/null)" ]] && [[ -d "$persist_ssh_dir" ]]; then
        cp -a "$persist_ssh_dir/." "$local_ssh_dir/" 2>/dev/null || true
    fi

    touch "$local_authorized_keys"
    chown "$NODE_USER:$NODE_USER" "$local_authorized_keys"
    chmod 600 "$local_authorized_keys"
    if [[ -n "$BOOTSTRAP_AUTHORIZED_KEY" ]]; then
        if ! grep -Fqx "$BOOTSTRAP_AUTHORIZED_KEY" "$local_authorized_keys"; then
            printf '%s\n' "$BOOTSTRAP_AUTHORIZED_KEY" >> "$local_authorized_keys"
        fi
    fi
    chown -R "$NODE_USER:$NODE_USER" "$local_ssh_dir"
    chmod 700 "$local_ssh_dir"
    find "$local_ssh_dir" -type f -exec chmod 600 {} + 2>/dev/null || true
    find "$local_ssh_dir" -type d -exec chmod 700 {} + 2>/dev/null || true

    run_as_user "cp -a '$local_ssh_dir/.' '$persist_ssh_dir/'" 2>/dev/null || true
    run_as_user "find '$persist_ssh_dir' -type f -name authorized_keys -exec chmod 600 {} +" 2>/dev/null || true
}

disable_suspend() {
    systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
    mkdir -p /etc/systemd/logind.conf.d
    cat > /etc/systemd/logind.conf.d/10-no-suspend.conf << 'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF
    systemctl restart systemd-logind || true
}

bind_apt_cache() {
    local cache_dir="$PERSIST_ROOT/apt-archives"
    if ! persist_root_supports_root_metadata; then
        if mountpoint -q /var/cache/apt/archives; then
            log "Unmounting stale persistent apt cache bind mount from /var/cache/apt/archives"
        fi
        reset_local_apt_cache_dir
        log "Skipping persistent apt cache bind mount on $PERSIST_ROOT because root metadata writes are not supported"
        return 0
    fi
    ensure_dir "$cache_dir"
    ensure_dir /var/cache/apt/archives
    if ! mountpoint -q /var/cache/apt/archives; then
        mount --bind "$cache_dir" /var/cache/apt/archives
    fi
}

configure_mounts() {
    local bigmirror_source bigmirror_fstype nvme_source nvme_fstype

    require_mountpoint "$BIGMIRROR_MOUNT"
    require_mountpoint "$NVME_MOUNT"

    bigmirror_source=$(current_mount_source "$BIGMIRROR_MOUNT")
    bigmirror_fstype=$(current_mount_fstype "$BIGMIRROR_MOUNT")
    nvme_source=$(current_mount_source "$NVME_MOUNT")
    nvme_fstype=$(current_mount_fstype "$NVME_MOUNT")

    if [[ -n "$bigmirror_source" && -n "$bigmirror_fstype" ]]; then
        if [[ "$bigmirror_fstype" == "nfs"* ]]; then
            ensure_fstab_entry "$bigmirror_source" "$BIGMIRROR_MOUNT" "$bigmirror_fstype" "defaults,_netdev,nofail,x-systemd.automount" "0 0"
        else
            ensure_fstab_entry "$bigmirror_source" "$BIGMIRROR_MOUNT" "$bigmirror_fstype" "defaults,nofail" "0 2"
        fi
    fi

    if [[ -n "$nvme_source" && -n "$nvme_fstype" ]]; then
        ensure_fstab_entry "$nvme_source" "$NVME_MOUNT" "$nvme_fstype" "defaults,nofail" "0 2"
    fi
}

configure_apt_sources() {
    # Write a complete sources.list including live media and non-free repos.
    source /etc/os-release
    suite=${VERSION_CODENAME:-stable}

    cat > /etc/apt/sources.list << EOF
deb [trusted=yes] file:/run/live/medium ${suite} main non-free-firmware
deb http://deb.debian.org/debian/ ${suite} main contrib non-free non-free-firmware
deb-src http://deb.debian.org/debian/ ${suite} main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${suite}-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian/ ${suite}-updates main contrib non-free non-free-firmware
EOF

    # Remove any stale live-media-only list files from /etc/apt/sources.list.d
    find /etc/apt/sources.list.d/ -name '*.list' \
        -exec grep -qlE 'file:/run/live' {} \; -delete 2>/dev/null || true
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    configure_apt_sources || true
    apt-get update
    apt-get install -y --no-install-recommends \
        openssh-server \
        nfs-common \
        sudo \
        curl \
        git \
        ca-certificates \
        tmux \
        ocl-icd-libopencl1 \
        firmware-nvidia-graphics \
        nvidia-opencl-icd \
        btop || true
}

install_nvidia_drivers() {
    export DEBIAN_FRONTEND=noninteractive
    configure_apt_sources || true
    apt-get update
    apt-get install -y --no-install-recommends nvidia-driver nvidia-kernel-dkms nvidia-opencl-icd ocl-icd-libopencl1 firmware-nvidia-graphics || true

    # Try to install matching headers if available
    KVER=$(uname -r)
    headers_pkg="linux-headers-${KVER}"
    if ! dpkg -s "$headers_pkg" >/dev/null 2>&1; then
        if apt-cache show "$headers_pkg" >/dev/null 2>&1; then
            apt-get install -y --no-install-recommends "$headers_pkg" || true
        fi
    fi

    # Rebuild DKMS for current kernel and log
    dkms autoinstall -k "${KVER}" 2>&1 | tee /var/log/dkms-autoinstall.log || true

    # Try to unload nouveau and load nvidia (best-effort; may fail on live media)
    for m in nouveau drm_kms_helper drm; do
        if lsmod | grep -q "^$m"; then
            modprobe -r "$m" 2>/dev/null || true
        fi
    done
    modprobe -v nvidia || true

    # Create an OpenCL ICD vendor file if package didn't
    if [[ ! -d /etc/OpenCL/vendors ]]; then
        mkdir -p /etc/OpenCL/vendors
    fi
    if [[ ! -f /etc/OpenCL/vendors/nvidia.icd ]]; then
        libpath=$(find /usr -name 'libnvidia-opencl.so*' 2>/dev/null | head -n1 || true)
        if [[ -n "$libpath" ]]; then
            printf '%s\n' "$libpath" > /etc/OpenCL/vendors/nvidia.icd || true
        fi
    fi

    # Write a safe nouveau blacklist without forcing initramfs update on live images
    cat > /etc/modprobe.d/blacklist-nouveau.conf << 'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
    if mountpoint -q /run/live || mountpoint -q /ro || ! [ -w / ]; then
        echo "Live/read-only system: skipping update-initramfs"
    else
        update-initramfs -u -k all || true
    fi
}

ensure_user() {
    if ! id "$NODE_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash "$NODE_USER"
    fi
    usermod -aG sudo "$NODE_USER"
    restore_persisted_password_hash
}

write_state() {
    ensure_dir "$PERSIST_ROOT"
    cat > "$PERSIST_ROOT/bootstrap-state.env" << EOF
NODE_NAME=${NODE_NAME}
NODE_USER=${NODE_USER}
PERSIST_ROOT=${PERSIST_ROOT}
BIGMIRROR_MOUNT=${BIGMIRROR_MOUNT}
NVME_MOUNT=${NVME_MOUNT}
BOOTSTRAP_AUTHORIZED_KEY=${BOOTSTRAP_AUTHORIZED_KEY}
LAST_BOOTSTRAP=$(date -Is)
HOSTNAME=$(hostname)
BIGMIRROR_SOURCE=$(current_mount_source "$BIGMIRROR_MOUNT")
NVME_SOURCE=$(current_mount_source "$NVME_MOUNT")
EOF
}

install_self_copy() {
    ensure_dir "$PERSIST_ROOT/bin"
    cp "$0" "$PERSIST_ROOT/bin/bootstrap-standard-liveusb.sh"
    chmod +x "$PERSIST_ROOT/bin/bootstrap-standard-liveusb.sh"
}

copy_dnetc_to_user() {
    # Copy the distributed.net OpenCL client folder into the user's Downloads if present
    local srcs=(
        "$PERSIST_ROOT/home/$NODE_USER/Downloads/dnetc521-linux-amd64-opencl"
        "$PERSIST_ROOT/Downloads/dnetc521-linux-amd64-opencl"
        "$BIGMIRROR_MOUNT/dnetc521-linux-amd64-opencl"
        "/run/live/medium/dnetc521-linux-amd64-opencl"
    )
    local dest="/home/$NODE_USER/Downloads"
    install -d -m 0755 -o "$NODE_USER" -g "$NODE_USER" "$dest"
    for s in "${srcs[@]}"; do
        if [[ -d "$s" ]]; then
            rsync -a --delete "$s/" "$dest/dnetc521-linux-amd64-opencl/" || true
            chown -R "$NODE_USER:$NODE_USER" "$dest/dnetc521-linux-amd64-opencl" || true
            log "Copied dnetc folder from $s to $dest/dnetc521-linux-amd64-opencl"
            return 0
        fi
    done
}

log "Using persistence root: $PERSIST_ROOT"
configure_mounts
bind_apt_cache
ensure_user
copy_dnetc_to_user
persist_current_password_hash
persist_ssh_host_keys
persist_user_ssh
systemctl enable --now ssh
disable_suspend
install_packages
install_nvidia_drivers
install_self_copy
write_state

log "Bootstrap complete"
log "Re-run after each live-USB boot with: sudo $PERSIST_ROOT/bin/bootstrap-standard-liveusb.sh"

# Ensure root can login with empty password and SSH permits it (idempotent)
configure_empty_root_ssh() {
    # remove root password
    passwd -d root >/dev/null 2>&1 || true

    # add pam nullok rule if not present
    if ! grep -q -E '^auth\s+\[success=1 default=ignore\]\s+pam_unix.so\s+nullok' /etc/pam.d/common-auth 2>/dev/null; then
        printf '%s\n' 'auth    [success=1 default=ignore]    pam_unix.so nullok' >> /etc/pam.d/common-auth
    fi

    # ensure sshd allows root login and empty passwords
    if grep -q '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config || true
    else
        printf '%s\n' 'PermitRootLogin yes' >> /etc/ssh/sshd_config
    fi
    if grep -q '^PermitEmptyPasswords' /etc/ssh/sshd_config 2>/dev/null; then
        sed -i 's/^PermitEmptyPasswords.*/PermitEmptyPasswords yes/' /etc/ssh/sshd_config || true
    else
        printf '%s\n' 'PermitEmptyPasswords yes' >> /etc/ssh/sshd_config
    fi

    systemctl restart ssh || true
}

configure_empty_root_ssh
