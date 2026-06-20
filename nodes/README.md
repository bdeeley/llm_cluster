# LLM Node Live ISO — Build & Deploy Guide

## What this is

Two custom Debian 12 live ISOs that turn Windows machines into
GPU-accelerated LLM inference nodes with zero permanent installation.
Boot from USB, everything runs in RAM. Pull the stick and Windows
comes back untouched.

## Cluster layout

| Node         | Machine              | GPU           | VRAM  |
|--------------|----------------------|---------------|-------|
| Local (house)| 2x Xeon 32c / 160 GB | 2× RTX 3060   | 24 GB |
| **node-a**   | 5800X3D (shop)       | RTX 3090      | 24 GB |
| **node-b**   | Next-gen CPU (shop)  | RTX 4070      | 12 GB |
| **Total**    |                      |               | **60 GB** |

Combined VRAM is enough to run 70B models fully in VRAM across the cluster.

---

## Build the ISOs (run once on your local machine)

```bash
cd nodes/
sudo apt-get install -y squashfs-tools xorriso wget
sudo ./build.sh
```

Build time: ~30–60 min per ISO (mostly squashfs compress + package download).
Output: `debian-llm-node-a.iso` and `debian-llm-node-b.iso`

---

## Flash to USB

```bash
# Replace /dev/sdX with your USB device (check with lsblk)
sudo dd if=debian-llm-node-a.iso of=/dev/sdX bs=4M status=progress && sync
sudo dd if=debian-llm-node-b.iso of=/dev/sdY bs=4M status=progress && sync
```

Label the sticks so you know which is which.

---

## Boot procedure (on each Windows machine)

1. Insert USB stick
2. Power on → press boot key (usually F8, F11, or F12)
3. Select the USB device from the boot menu
4. Debian live boots to a login prompt in ~60 seconds
5. Login: `root` / password: `llmnode`
6. **First boot only:** setup runs automatically (~5 min for NVIDIA driver build)
7. Run `node-status` to confirm GPU + Ollama are running

The machine is ready when you see `NVIDIA driver OK` in the output.

## Standard Live USB fallback

If the custom node ISO does not boot, use a stock Debian or Ubuntu live USB and
replay the node bootstrap from shared storage.

The current recovery path is `nodes/bootstrap-standard-liveusb.sh`.
It assumes these are already mounted in the live session:

- `/NVME` for persistent node state and apt cache
- `/BIGMIRROR` for shared models and cluster assets

What the bootstrap does:

- installs `openssh-server`, `nfs-common`, `sudo`, and base admin tools
- ensures user `bdeeley` exists and is in `sudo`
- seeds `authorized_keys` for `bdeeley` with the default admin key unless `BOOTSTRAP_AUTHORIZED_KEY` overrides it
- persists SSH host keys and a backup copy of `~/.ssh` under `/NVME/live-bootstrap/<node>`, then restores a local `~/.ssh` each boot so `sshd` accepts `authorized_keys`
- writes the current `/BIGMIRROR` and `/NVME` mounts into `/etc/fstab`
- disables suspend and other sleep targets for unattended serving
- copies itself into `/NVME` so it can be rerun after the next live boot

Example:

```bash
sudo mkdir -p /BIGMIRROR /NVME
# mount /BIGMIRROR and /NVME first
sudo bash /path/to/test/nodes/bootstrap-standard-liveusb.sh
```

Important limitation: a stock live USB still loses installed packages on reboot.
Using `/NVME` makes the state and package cache persistent, but you still need to
rerun the bootstrap after each boot unless you add real live-media persistence or
build a working custom image.

## 3090 exo bootstrap

For the Debian live USB on the RTX 3090 host, the second-stage exo bootstrap is
`nodes/bootstrap-exo-3090-liveusb.sh`.

It layers on top of the `/NVME` base bootstrap and does the exo-specific work:

- installs the extra toolchain and NVIDIA packages needed for a live Debian exo node
- persists the exo checkout, config, cache, event log, and keypair paths under `/NVME`
- uses `/BIGMIRROR/exo-models-debian` for shared model storage
- builds the dashboard and runs `uv sync --extra mlx-cuda12`
- writes a persistent `go` launcher and a `exo-remote-3090.service` follower service

The default repo source is `/BIGMIRROR/exo`. If your patched exo checkout lives
somewhere else, set `EXO_REPO_SOURCE` before running it.

Example:

```bash
sudo bash /path/to/test/nodes/bootstrap-exo-3090-liveusb.sh
```

---

## Connect to your local Ollama setup

On your local machine, point Cline (or any Ollama client) at the
remote nodes by adding them as additional endpoints. Get the IPs
from `node-status` on each node.

### Option A — Use nodes independently (simplest)

Each node runs its own Ollama. Switch between them in Cline's model
selector by changing the API endpoint.

### Option B — Load-balance with nginx

Install nginx on your local machine:

```nginx
# /etc/nginx/conf.d/ollama-lb.conf
upstream ollama_cluster {
    server localhost:11434;          # local
    server <node-a-ip>:11434;        # RTX 3090
    server <node-b-ip>:11434;        # RTX 4070
}
server {
    listen 12000;
    location / { proxy_pass http://ollama_cluster; }
}
```

Then point Cline at `http://localhost:12000`.

### Option C — exo distributed inference

If all three machines are on the same LAN, exo automatically
discovers peers and splits model layers across GPUs. Start exo on
your local machine too:

```bash
pip install exo-explore
exo
```

---

## Day-to-day use

| Task | Command |
|------|---------|
| Check node status | `node-status` |
| Watch setup logs | `journalctl -u llm-node-setup -f` |
| List Ollama models | `ollama list` |
| Pull a model | `ollama pull qwen2.5-coder:32b` |
| Restart Ollama | `systemctl restart ollama-node` |
| Restart exo | `systemctl restart exo-node` |
| SSH from local | `ssh root@<node-ip>` |

---

## Security note

The default SSH password (`llmnode`) is intentional for quick setup.
Change it immediately on first boot if these machines are reachable
outside your LAN:

```bash
passwd root
```

---

## Customising the ISOs

- **Add models to auto-pull:** edit the `ollama pull` line in `overlay/opt/node-setup.sh`
- **Change Ollama port:** edit `OLLAMA_PORT` in `node-a.conf` / `node-b.conf`
- **Add packages:** add `apt-get install` lines inside the `CHROOT` block in `build.sh`
- Rebuild with `sudo ./build.sh` after any change

---

## How the live system works

```
USB stick
└── ISO
    ├── isolinux/        ← bootloader
    └── live/
        ├── vmlinuz      ← kernel
        ├── initrd.img   ← initramfs
        └── filesystem.squashfs  ← compressed root (read-only)

At boot:
  squashfs (read-only) ──┐
                          ├── overlayfs → / (in RAM)
  tmpfs (RAM) ────────────┘

All writes go to RAM. Original squashfs untouched.
Pull USB → Windows boots normally.
```

---

## CRITICAL: EXO Bootstrap Edge Cases (June 2026)

**This section documents issues encountered during theplague bootstrap. Must be followed for next deployment.**

### Issue #1: PEP 668 Pip Restriction (Debian 13+)
**Problem**: `pip3 install --user` fails with "externally-managed-environment" error
**Solution**: Use venv instead
```bash
cd ~/exo
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip uv
uv pip install -e .
```
**Important**: Do NOT use `--break-system-packages` flag

### Issue #2: Missing Git
**Problem**: Fresh OS has no git after format
**Solution**: Install early
```bash
sudo apt-get update
sudo apt-get install -y git curl wget build-essential python3-dev python3-pip python3-venv
```
**Do this BEFORE cloning exo**

### Issue #3: Missing Dashboard Directory (CRITICAL)
**Problem**: exo startup fails with "Directory '/home/bdeeley/exo/dashboard/dist' does not exist"
**Solution**: Create placeholder BEFORE starting service
```bash
mkdir -p /home/bdeeley/exo/dashboard/dist
echo 'placeholder' > /home/bdeeley/exo/dashboard/dist/index.html
```
**Why**: Dashboard is only for UI; cluster works fine without real build, but exo refuses to start without the directory existing

### Issue #4: Dashboard on All Nodes
Dashboard directory creation is required on:
- maxpower master: `/home/bdeeley/exo/dashboard/dist`
- maxpower worker: `/home/bdeeley/exo/dashboard/dist`
- Remote nodes: `/home/bdeeley/exo/dashboard/dist`

### Issue #5: Service Arguments Are Version-Specific
**Problem**: Old documentation references `--node-port` (invalid)
**Correct argument**: `--libp2p-port`
```bash
# WRONG:
exo --node-port 5679

# CORRECT:
exo --api-port 52415 --libp2p-port 5679 --bootstrap-peers /ip4/172.16.0.28/tcp/5678,...
```
**Always check**: `exo --help` for current valid arguments if bootstrapping differs

### Issue #6: Pidfile Conflicts on Multi-Process Nodes
**Problem**: Master and worker processes on same machine fight over ~/.cache/exo/exo.pid
**Solution**: Separate cache directories
```bash
# Master service: (default)
Environment="XDG_CACHE_HOME=/home/bdeeley/.cache/exo"

# Worker service:
Environment="XDG_CACHE_HOME=/home/bdeeley/.cache/exo-worker"
```

### Issue #7: HuggingFace Token Management (CRITICAL)
**Current approach** (as of June 2026):
- Set `HF_TOKEN=""` (empty string)
- Point `HF_HOME=/BIGMIRROR/exo-models-local` (shared NFS cache)
- All models pre-cached, no downloads needed, no auth failures

**Previous approach** (caused failures):
- Invalid tokens in node-config.env → silent HTTP 401 errors on remote nodes
- Errors only visible in central logging, not in API responses

**For next session**: Keep HF_TOKEN empty unless you need HF authentication

### Bootstrap Order (Recommended for Next Time)
```bash
# 1. System packages (must be first)
sudo apt-get update
sudo apt-get install -y git curl wget build-essential python3-dev python3-pip python3-venv

# 2. Clone and checkout exo at specific commit
cd ~
git clone https://github.com/exo-explore/exo.git exo
cd exo
git checkout 74e9fe15  # Or current stable commit

# 3. Python venv + uv
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip uv
uv pip install -e .

# 4. Create cache dirs (separate per-node if multi-process)
mkdir -p ~/.local/share/exo-<nodename>
mkdir -p ~/.cache/exo-<nodename>

# 5. Dashboard workaround (CRITICAL - exo won't start without this)
mkdir -p ~/exo/dashboard/dist
echo 'placeholder' > ~/exo/dashboard/dist/index.html

# 6. Systemd service (verify --libp2p-port and bootstrap-peers)
sudo cp exo.service /etc/systemd/system/exo.service
sudo systemctl daemon-reload
sudo systemctl enable exo.service

# 7. Start and verify
sudo systemctl start exo.service
sleep 4
sudo systemctl status exo.service

# 8. Verify mounts
mount | grep -E 'BIGMIRROR|NVME'

# 9. Check cluster state (from master only)
curl -s http://localhost:52415/state | jq '.'
```

### Central Logging (MANDATORY for ALL Sessions)
All exo service ExecStart commands MUST use centralized logging wrapper:
```bash
ExecStart=/BIGMIRROR/exo-wrapper-simple.sh /home/bdeeley/.local/bin/uv run exo ...
```
This captures auth errors, network issues, and runtime failures that are otherwise invisible to API clients.

**Monitoring**:
```bash
./monitor-logs.sh  # From /home/bdeeley/test directory
```

---
