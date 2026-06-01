Cluster handover — debian 3090 exo node bootstrap
===============================================

Purpose
-------
This document summarizes the current cluster topology, the node roles, the live-USB + NFS persistence strategy, and the work performed to bootstrap a Debian 13 (trixie) RTX 3090 host as an exo follower. It is written so another agent or human can pick up the remaining tasks and continue provisioning or debugging without extra context.

Workspace and important paths
-----------------------------
- Repo root: /home/bdeeley/test
- Base bootstrap script: nodes/bootstrap-standard-liveusb.sh
- 3090-specific bootstrap: nodes/bootstrap-exo-3090-liveusb.sh
- Persisted bootstrap state: /NVME/live-bootstrap/<node>/bootstrap-state.env
- exo node persistent root: /NVME/exo-node-3090
- Shared model/repo mount: /BIGMIRROR

Cluster topology and intent
---------------------------
- A small exo cluster with a master node (172.16.0.174) and followers.
- Target node `debian` is a physical host with an RTX 3090. The goal is to make it a reproducible follower that boots from a live Debian USB, mounts persistence at `/NVME` (NFS-shared), and can be remote-managed via SSH.

Design constraints and important environmental facts
--------------------------------------------------
- `/NVME` is an NFS share that uses root-squash. Files created on `/NVME` appear as `nobody:nogroup` and root cannot reliably chown/chmod them.
- Live USB environment: kernel and running environment come from the live image. Installing packages is allowed, but kernel-related changes (modules) may require matching headers or a reboot into the header-matching kernel.
- Networked apt sources are used; system clock must be correct for apt signature validation.

What was implemented
---------------------
1. Base bootstrap (`nodes/bootstrap-standard-liveusb.sh`):
   - Ensures `NODE_USER` exists and belongs to `sudo`.
   - Persists current `shadow` password hash to `${PERSIST_ROOT}/shadow-${NODE_USER}.hash` and restores it on re-run (avoids clearing the password).
   - Persists SSH host keys into `${PERSIST_ROOT}/ssh-host-keys` but always copies host keys to `/etc/ssh/` on boot (without preserving ownership) to avoid chown errors on NFS.
   - Reworked `.ssh` persistence: the live local `~/.ssh` is authoritative. The script seeds `~/.ssh/authorized_keys` locally with `BOOTSTRAP_AUTHORIZED_KEY`, sets correct owner and modes, then *backs up* the local `.ssh` to `/NVME` (instead of the other way around). This prevents stale NFS copies from overwriting a freshly-added key.
   - Probes whether the persistence root supports root metadata writes (chown), and if not, avoids bind-mounting apt cache from `/NVME` and instead uses the local `/var/cache/apt/archives`.
   - Disables suspend targets and installs core packages (openssh-server, nfs-common, sudo, curl, git, ca-certificates, tmux).
   - Copies itself into `$PERSIST_ROOT/bin` for re-run after boot.

2. 3090 exo bootstrap (`nodes/bootstrap-exo-3090-liveusb.sh`):
   - Configures `sources.list` to include `main contrib non-free non-free-firmware` so NVIDIA packages are available.
   - Installs exo prerequisites and NVIDIA stack (`nvidia-driver`, `nvidia-cuda-toolkit`, `nvidia-smi` if available).
   - Ensures kernel headers for the running kernel are present; installs `linux-headers-$(uname -r)` if apt has them.
   - Creates persistent exo root, syncs the exo repo (from `/BIGMIRROR/exo` or git), builds dashboard, prepares virtualenv and launcher, and writes a systemd service `exo-remote-3090.service`.
   - Launcher sets environment variables (CUDA paths, EXO directories) and execs the `uv run exo` command.

What I ran and validated (summary)
----------------------------------
- Staged patched `bootstrap-standard-liveusb.sh` and executed it on `debian` (via `scp` + `ssh 'sudo /tmp/bootstrap-standard-liveusb.sh'`).
  - Result: `~/.ssh/authorized_keys` set with proper owner/mode; batch-mode SSH confirmed working (`ssh -o BatchMode=yes debian` -> `SSH_OK`).
- Fixed system clock (temporary) using `sudo date -u -s '...'` to remove apt signature validation errors.
Cluster handover — debian 3090 exo node bootstrap
===============================================

Purpose
-------
This document summarizes the current cluster topology, node roles, the live-USB + NFS persistence strategy, and the recent work to bootstrap a Debian 13 (trixie) RTX 3090 host as an exo follower. It is targeted at another engineer or agent who will continue provisioning, debugging, or hardening the node.

Workspace and important paths
-----------------------------
- Repo root: /home/bdeeley/test
- Base bootstrap script: nodes/bootstrap-standard-liveusb.sh
- 3090-specific bootstrap: nodes/bootstrap-exo-3090-liveusb.sh
- Persisted bootstrap state: /NVME/live-bootstrap/<node>/bootstrap-state.env
- exo node persistent root: /NVME/exo-node-3090
- Shared model/repo mount: /BIGMIRROR
- Writable user checkout used during testing: /home/bdeeley/exo (copied from /BIGMIRROR/exo)

Cluster topology and intent
---------------------------
- Small exo cluster with a master node (172.16.0.174) and followers.
- Target node `debian` is a physical host with an RTX 3090. Goal: reproducible follower that boots from a live Debian USB, mounts persistence at `/NVME` (NFS-shared), and can be remotely managed via SSH and run exo with GPU support.

Design constraints and important environmental facts
--------------------------------------------------
- `/NVME` is an NFS share using root-squash. Files created on `/NVME` appear as `nobody:nogroup` and root cannot reliably chown/chmod them.
- Live USB environment: kernel and running environment come from the live image. Kernel module changes often require matching headers or a reboot into the headers-matching kernel.
- Apt signature verification requires correct system time; the bootstrap corrects the clock when necessary.

What was implemented
---------------------
1. Base bootstrap (`nodes/bootstrap-standard-liveusb.sh`)
   - Ensures `NODE_USER` exists and has `sudo` privileges.
   - Persists the current password hash to `${PERSIST_ROOT}/shadow-${NODE_USER}.hash` and restores it on re-run (does not clear passwords).
   - Persists SSH host keys to `${PERSIST_ROOT}/ssh-host-keys` and restores them to `/etc/ssh/` on boot (copies without preserving ownership to avoid NFS chown failures).
   - Makes the live local `~/.ssh` authoritative: seeds `~/.ssh/authorized_keys` with `BOOTSTRAP_AUTHORIZED_KEY`, fixes owner/mode locally, then backs up that local `.ssh` to `/NVME` (prevents stale NFS copies from clobbering live keys).
   - Probes whether the persistence root supports root metadata; if not, it avoids bind-mounting apt cache from `/NVME` and uses the local apt cache instead.
   - Installs core packages (openssh-server, nfs-common, sudo, curl, git, ca-certificates, tmux) and copies itself into `$PERSIST_ROOT/bin` for re-run.

2. 3090 exo bootstrap (`nodes/bootstrap-exo-3090-liveusb.sh`)
   - Ensures `sources.list` includes `main contrib non-free non-free-firmware` so NVIDIA packages are available.
   - Installs exo prerequisites and the NVIDIA userspace packages (`nvidia-driver`, CUDA packages, `nvidia-smi` when available).
   - Attempts to install kernel headers for the running kernel (`linux-headers-$(uname -r)`), allowing DKMS to build against the running kernel when headers exist.
   - Prepares a persistent exo root and attempts to sync/build the repo (from `/BIGMIRROR/exo`), writes a launcher, and a service unit `exo-remote-3090.service`.
   - Launcher sets CUDA-related envvars and runs `uv run exo`.

What I ran and validated (recent actions)
----------------------------------------
- Executed `bootstrap-standard-liveusb.sh` on `debian`: local `~/.ssh/authorized_keys` was populated and `ssh` batch-mode works.
- Fixed the system clock when apt signature errors occurred so apt can update.
- Executed `bootstrap-exo-3090-liveusb.sh`: apt installed prerequisites and attempted DKMS builds; kernel headers were installed where available.
- Because `/BIGMIRROR` is not writable by the live user (NFS/root-squash), I copied `/BIGMIRROR/exo` into a writable checkout at `/home/bdeeley/exo` and adjusted ownership to the user so `.venv` can be created.
- Installed the `uv` runner into `/home/bdeeley/.local/bin/uv` (if missing) and launched exo from `/home/bdeeley/exo` using `setsid` in the background.
  - PID: 63140 (background process running `uv run exo` at the time of launch)
  - Log file on the node: `/tmp/exo-logs/remote-follower.log`
  - Current log status (at the time of update): `.venv` being created and many Python/Rust dependencies were downloading and building (pip wheels, rust build for exo, playwright and nodejs binary wheels, etc.).

Observed blockers and notes
---------------------------
- NVIDIA kernel module insertion: earlier DKMS builds were present after headers installed, but kernel-module binding initially failed (common causes: running kernel not matching installed headers, Secure Boot blocking unsigned modules, or nouveau not removed).
- `/BIGMIRROR` being writable only for the owner prevents creating `.venv` on that mount; copying to a home directory was necessary to allow `uv` to build the environment.

Immediate next steps and remediation
-----------------------------------
1. Verify exo fully finishes starting (watch `/tmp/exo-logs/remote-follower.log`) and confirm process remains alive.

   Commands to run on the node:

```bash
ssh debian
# follow logs
tail -F /tmp/exo-logs/remote-follower.log
# verify process
ps -ef | grep '[u]v run exo'
```

2. Make GPU drivers survive reboots (recommended flow):
   - Reboot node into the kernel that matches installed headers (if headers were installed for a different kernel, reboot into that kernel), then run:

```bash
ssh debian
sudo modprobe nvidia && sudo nvidia-smi
sudo systemctl restart exo-remote-3090.service || sudo systemctl start exo-remote-3090.service
```

3. If module loading still fails, check Secure Boot and MOK status and kernel logs:

```bash
ssh debian
sudo apt-get install -y mokutil
sudo mokutil --sb-state
sudo dmesg | tail -n 200
sudo journalctl -u exo-remote-3090.service -n 200 --no-pager
```

4. Persist a runnable systemd unit that uses the writable checkout and explicit envvars (example unit snippet below). After you confirm the launcher command and paths, enable the unit so exo survives reboots.

Example minimal service to adapt and enable (save as `/etc/systemd/system/exo-remote-3090.service`):

```ini
[Unit]
Description=exo remote follower (3090)
After=network.target

[Service]
Type=simple
User=bdeeley
WorkingDirectory=/home/bdeeley/exo
Environment=EXO_DEFAULT_MODELS_DIR=/home/bdeeley/.local/share/exo/models
Environment=EXO_EVENT_LOG_DIR=/home/bdeeley/.local/share/exo/event_log-remote
ExecStart=/home/bdeeley/.local/bin/uv run exo --no-master-candidate --api-port 52415 --libp2p-port 5679 --bootstrap-peers /ip4/172.16.0.174/tcp/5678
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

Known issues and caveats
------------------------
- Live kernel vs installed headers: DKMS builds are only useful against headers that match the running kernel; a reboot into the kernel matching installed headers is often necessary.
- Secure Boot: unsigned DKMS modules will be blocked; either enroll keys via MOK or disable Secure Boot.
- NFS root-squash: the bootstrap intentionally does not rely on chown/chmod on `/NVME` and uses local copies where ownership is required.

How to hand off
----------------
- Files to inspect / edit:
  - `nodes/bootstrap-standard-liveusb.sh`
  - `nodes/bootstrap-exo-3090-liveusb.sh`
  - `/NVME/live-bootstrap/<node>/bootstrap-state.env`
  - `/BIGMIRROR/exo` and the writable copy `/home/bdeeley/exo`

- Quick reproduce steps:
  1. Ensure `/BIGMIRROR` and `/NVME` are available/mounted.
  2. Run the base bootstrap: `scp nodes/bootstrap-standard-liveusb.sh debian:/tmp/ && ssh -t debian 'sudo /tmp/bootstrap-standard-liveusb.sh'`.
  3. Run the 3090 bootstrap: `scp nodes/bootstrap-exo-3090-liveusb.sh debian:/tmp/ && ssh -t debian 'sudo /tmp/bootstrap-exo-3090-liveusb.sh'`.
  4. If `/BIGMIRROR` is not writable for `.venv`, copy the repo into the home directory and run exo from there or adjust permissions/ownership accordingly.

Next recommended tasks (ordered)
--------------------------------
1. Confirm exo finishes starting from `/home/bdeeley/exo` and stays running; capture final logs.
2. Create/enable a systemd unit that runs the verified launcher from a writable path (see example above).
3. Reboot into the kernel that matches installed headers and verify NVIDIA modules load and `nvidia-smi` works.
4. Detect Secure Boot and either document enrollment steps or add MOK enrollment to the bootstrap flow.
5. Harden the bootstrap so that driver swap and nouveau blacklisting only run when safe.

Contact / context
-----------------
- Work and scripts live in `/home/bdeeley/test`.
- Actions performed during this session: fixed SSH persistence, preserved password hash, copied `/BIGMIRROR/exo` to `/home/bdeeley/exo`, installed `uv`, and launched exo (PID 63140) — logs at `/tmp/exo-logs/remote-follower.log` on the node.

----------
End of updated handover file. Ask me to stream the exo logs, enable a systemd unit, or continue with Secure Boot checks and kernel reboots.