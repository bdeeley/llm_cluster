# EXO 3-Node Cluster: Comprehensive Status & Handover Document
**Date**: June 3, 2026  
**Status**: Instance creation working, runners blocked by MLX version mismatch  
**Primary Goal**: Load 40-70GB model (Qwen2.5-72B-Instruct-4bit, 40.9GB) on 3-GPU cluster

---

## EXECUTIVE SUMMARY

**✅ Working:**
- Instance creation via `/place_instance` API now succeeds with `min_nodes: 3`
- Cluster topology: 3 nodes connected via libp2p networking
- Central logging infrastructure operational
- Wrapper script properly configured for CUDA library paths

**❌ Blocking Issue:**
- **MLX version mismatch on debian node**: debian has MLX 0.31.2, maxpower/theplague have 0.32.0
- Symbol error prevents runner execution: `undefined symbol: _ZN3mlx4core4sqrtERKNS0_5arrayE...`
- Runners created but immediately fail with ImportError
- Model cannot load until runners are in RunnerReady state

**📋 Immediate Next Steps:**
1. Resolve MLX version mismatch (upgrade debian to 0.32.0 or downgrade other nodes)
2. Restart debian service
3. Monitor runner state transitions to RunnerReady
4. Test model inference once runners ready

---

## CLUSTER ARCHITECTURE

### Hardware Topology (72GB total VRAM)

| Node | Role | IP | CUDA GPU | GPU VRAM | System RAM | Storage |
|------|------|-----|----------|----------|-----------|---------|
| **maxpower** | Master | 172.16.0.174 | Quadro P6000 + RTX 3060 | 24+12=36GB | 50.7GB | /BIGMIRROR shared |
| **debian** | Worker 3090 | 172.16.0.14 | RTX 3090 | 24GB | 26.1GB | /NVME/debian-* |
| **theplague** | Worker 3060/4090 | 172.16.0.175 | RTX 3060 + RTX 4090 | 12+24=36GB | 27.8GB | System mount |

### Network Configuration
- **libp2p bootstrap**: All nodes reachable via `--bootstrap-peers /ip4/172.16.0.174/tcp/5678,/ip4/172.16.0.175/tcp/5679`
- **maxpower libp2p ports**: :5678 (primary master), :5680 (worker candidate)
- **debian libp2p port**: :5679
- **theplague libp2p port**: :5679
- **API ports**: All nodes expose :52415 for `/place_instance` requests

### Model Target
- **Model**: `mlx-community/Qwen2.5-72B-Instruct-4bit`
- **Size**: 40.9GB (safetensors sharded)
- **Architecture**: 80 layers, 8192 hidden size, 8 key-value heads
- **Sharding Strategy**: Pipeline parallelism across 3 nodes (MlxRing)
- **Expected shard distribution**: ~13.6GB per node

---

## STORAGE & SYMLINK STRUCTURE

### /BIGMIRROR: Central Shared Storage
**Purpose**: Shared mount accessible from all nodes for logs, models, and coordination  
**Location**: Master NFS/SMB mount at `/BIGMIRROR`  
**What's stored**:
- `exo-cluster.log` - Central aggregated log from all 3 nodes
- `exo-models-local/` - Cached HuggingFace model downloads
- `exo-wrapper-simple.sh` - Pre-execution wrapper script (all nodes source this)
- Script logs and coordination files

**Key Script**: `/BIGMIRROR/exo-wrapper-simple.sh`
- Executed as `ExecStart=` in all 3 systemd services
- Sets up `LD_LIBRARY_PATH` with CUDA libraries before Python subprocess spawning
- Contains startup diagnostics, health checks, and network verification

### /NVME: Debian Node Local Storage (Post-Disk-Shortage Fix)
**Why /NVME**: Original /home partition on debian was 100% full (3.6GB live USB), blocking package installations

**Migration performed**:
```
/home/bdeeley/.cache      → /NVME/debian-cache (with symlink)
/home/bdeeley/.local      → /NVME/debian-local (with symlink)
/home/bdeeley/exo         → /NVME/debian-exo   (with symlink)
```

**Current Symlink Status** (verified working):
```bash
# On debian (172.16.0.14):
/home/bdeeley/.cache → /NVME/debian-cache  ✓ resolves
/home/bdeeley/.local → /NVME/debian-local  ✓ resolves (contains CUDA libs)
/home/bdeeley/exo    → /NVME/debian-exo    ✓ resolves (contains venv)
```

**Storage Paths on debian**:
- MLX installed at: `/NVME/debian-exo/.venv/lib/python3.13/site-packages/mlx-0.31.2.dist-info`
- CUDA libs at: `/NVME/debian-local/lib/python3.13/site-packages/nvidia/`
- Venv Python at: `/NVME/debian-exo/.venv/bin/python3`

---

## CURRENT PROBLEMS & ROOT CAUSES

### Problem 1: Instance Creation Blocked (✅ FIXED)
**Symptom**: `place_instance` API accepted requests but generated zero InstanceCreated events  
**Root Cause**: Requested `min_nodes: 4` but cluster only has 3 nodes  
**Placement Logic in `/home/bdeeley/exo/src/exo/master/placement.py`**:
- Lines 122-130: Filter cycles by size: `filter(lambda it: len(it) >= command.min_nodes, cycles)`
- With 3 nodes, only cycles of size 1, 2, 3 are possible
- Requesting 4 nodes → 0 valid cycles → placement fails
- Error logged: `"❌ PLACEMENT FAILED: No cycles found with sufficient memory"`

**Solution Applied**: Deploy with `min_nodes: 3` instead of `min_nodes: 4`  
**Verification**: Successful deployment returns:
```json
{
  "command_id": "bcf96a7a-1af6-4431-83ad-1832e250fc35",
  "message": "Command received",
  "model_card": {...}
}
```
Master logs show: `"✅ PLACEMENT COMPLETE: ca1223e0-26f placed on 3 nodes"`

### Problem 2: MLX Symbol Error on Debian (❌ ACTIVE BLOCKER)
**Symptom**: Runners created but immediately exit with code 1:
```
ImportError: /NVME/debian-exo/.venv/lib/python3.13/site-packages/mlx/core.cpython-313-x86_64-linux-gnu.so: 
undefined symbol: _ZN3mlx4core4sqrtERKNS0_5arrayESt7variantIJSt9monostateNS0_6StreamENS0_17ThreadLocalStreamENS0_6DeviceEEE
```

**Root Cause**: MLX version mismatch across nodes
```
maxpower:   mlx-0.32.0.dist-info
debian:     mlx-0.31.2.dist-info  ← MISMATCH!
theplague:  mlx-0.32.0.dist-info
```

**Why This Fails**:
- Binary MLX wheel compiled on 0.32.0 contains symbol definitions for `sqrt()` function
- Debian's 0.31.2 binary doesn't have same symbols (older ABI)
- When runner subprocess tries to import, linker can't find symbol → ImportError

**Error Location in Code Flow**:
1. Master creates instance: `place_instance(command)` ✅ succeeds
2. Master sends CreateRunner task to worker nodes
3. Worker's `plan.py` spawns runner subprocess: `AsyncProcess(target=entrypoint, ...)`
4. Runner subprocess imports MLX: `import mlx.core` ❌ fails with undefined symbol
5. Runner exits → RunnerFailed state
6. No DownloadCompleted events generated → model never loads

**Current Investigation Status**:
- `/BIGMIRROR/exo-wrapper-simple.sh` fixed to include `cuda_runtime/lib` and `cuda_nvrtc/lib` ✓
- Symlink structure verified working ✓
- CUDA libraries found at correct locations ✓
- **Issue remains**: MLX 0.31.2 binary incompatible with 0.32.0 on other nodes

---

## LOGGING INFRASTRUCTURE

### Central Log Aggregation
**Primary Log**: `/BIGMIRROR/exo-cluster.log` (aggregated from all 3 nodes)  
**How It Works**:
1. Each node's systemd service configured: `StandardOutput=journal StandardError=journal`
2. Pre-execution wrapper logs startup diagnostics via `systemd-cat`
3. Log forwarder (if running) pushes journalctl entries to central file
4. All 3 nodes successfully writing to central log

**Example Log Entry**:
```
Jun 03 19:04:11 maxpower exo-wrapper-simple.sh[1186933]: 
[ 07:04:11.1533PM | INFO ] Global runner df81b285: RunnerFailed
```

### Viewing Logs by Node
```bash
# Master (maxpower) - active exo.service
sudo journalctl -u exo.service -n 100 --no-pager

# Debian worker - exo-remote-3090.service
ssh bdeeley@172.16.0.14 "sudo journalctl -u exo-remote-3090.service -n 100 --no-pager"

# Theplague worker - exo.service  
ssh bdeeley@172.16.0.175 "sudo journalctl -u exo.service -n 100 --no-pager"

# Central aggregated log
tail -f /BIGMIRROR/exo-cluster.log
```

### Key Log Patterns to Watch
```bash
# Instance creation succeeded
grep "PLACEMENT COMPLETE" /BIGMIRROR/exo-cluster.log

# Runner state transitions (goal: reach RunnerReady)
grep "RunnerConnecting\|RunnerLoading\|RunnerReady" /BIGMIRROR/exo-cluster.log

# MLX import errors (current blocker)
grep "undefined symbol\|ImportError" /BIGMIRROR/exo-cluster.log

# Download progress
grep "DownloadCompleted\|Download.*bytes" /BIGMIRROR/exo-cluster.log

# Plan cycles (should show Instances: 1, Local runners: 1, Global runners: 3)
grep "Local runners:\|Global runners:\|Instances:" /BIGMIRROR/exo-cluster.log
```

---

## SERVICE CONFIGURATIONS

### Master Service: `/etc/systemd/system/exo.service` (maxpower)
```ini
[Service]
Type=simple
User=bdeeley
WorkingDirectory=/home/bdeeley/exo
Environment="LD_LIBRARY_PATH=/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/cublas/lib:..."
ExecStart=/BIGMIRROR/exo-wrapper-simple.sh /home/bdeeley/.local/bin/uv run exo \
  --force-master \
  --api-port 52415 \
  --libp2p-port 5678 \
  --bootstrap-peers /ip4/172.16.0.14/tcp/5679,/ip4/172.16.0.175/tcp/5679
StandardOutput=journal
StandardError=journal
```

### Debian Worker Service: `/etc/systemd/system/exo-remote-3090.service`
```ini
[Service]
Type=simple
User=bdeeley
WorkingDirectory=/NVME/debian-exo
Environment="LD_LIBRARY_PATH=/NVME/debian-exo/.venv/lib/python3.13/site-packages/nvidia/cublas/lib:..."
ExecStartPre=/BIGMIRROR/exo-cluster-health-check.sh
ExecStart=/BIGMIRROR/exo-wrapper-simple.sh /home/bdeeley/.local/bin/uv run exo \
  --api-port 52415 \
  --libp2p-port 5679 \
  --bootstrap-peers /ip4/172.16.0.174/tcp/5678,/ip4/172.16.0.174/tcp/5680,/ip4/172.16.0.175/tcp/5679
StandardOutput=journal
StandardError=journal
```

**Note**: Service unit's `LD_LIBRARY_PATH` should use `/NVME/debian-exo/` and `/NVME/debian-local/` absolute paths (not symlinks via `/home/bdeeley/`) to ensure subprocess inheritance.

### Theplague Worker Service: `/etc/systemd/system/exo.service`
- Similar to debian but with paths pointing to `/home/bdeeley/exo` (has system CUDA 12.4)
- Extra system CUDA path: `/usr/local/cuda-12.4/targets/x86_64-linux/lib`

---

## DEPLOYMENT WORKFLOW

### Current Successful Deployment Command
```bash
# Deploy with correct min_nodes=3 (not 4)
curl -s -X POST http://localhost:52415/place_instance \
  -H "Content-Type: application/json" \
  -d '{
    "model_id": "mlx-community/Qwen2.5-72B-Instruct-4bit",
    "min_nodes": 3
  }'

# Expected response:
# {
#   "command_id": "bcf96a7a-...",
#   "message": "Command received",
#   "model_card": {
#     "modelId": "mlx-community/Qwen2.5-72B-Instruct-4bit",
#     ...
#   }
# }
```

### Monitor Deployment Progress
```bash
# Watch plan cycles for runner state
sudo journalctl -u exo.service -f 2>&1 | grep -E "Local runners:|RunnerReady|RunnerFailed"

# Check instance creation
curl -s http://localhost:52415/state | python3 -m json.tool | grep -A5 "instances"

# View master logs
tail -f /BIGMIRROR/exo-cluster.log | grep -E "PLACEMENT|RUNNER|ERROR"
```

---

## FILES & CODE LOCATIONS

### Core EXO Framework
- **Master command handler**: `/home/bdeeley/exo/src/exo/master/main.py` (lines 360-412)
  - Receives PlaceInstance commands, logs ">>> [HANDLER] PlaceInstance command received"
  - Calls `place_instance()` from placement.py
  - Sends download commands to workers
  
- **Placement algorithm**: `/home/bdeeley/exo/src/exo/master/placement.py` (lines 108-355)
  - Line 122-130: Filters cycles by min_nodes requirement
  - Line 140-145: Filters by available memory
  - Line 252: Success log "✅ PLACEMENT COMPLETE"
  - **Root cause of initial failure**: Only supports N≤3 nodes with current topology
  
- **Worker runner spawning**: `/home/bdeeley/exo/src/exo/worker/runner/supervisor.py` (lines 200-280)
  - `create()` method spawns subprocess: `AsyncProcess(target=entrypoint, args=...)`
  - Runner tries to import MLX → **currently fails with symbol error**
  
- **API handler**: `/home/bdeeley/exo/src/exo/api/main.py` (lines 427-439)
  - POST `/place_instance` endpoint
  - Accepts `{model_id, min_nodes, sharding, instance_meta}`
  - Returns `{command_id, model_card, message}`

### Wrapper & Configuration
- **Pre-execution wrapper**: `/BIGMIRROR/exo-wrapper-simple.sh` (60+ lines)
  - Sets up LD_LIBRARY_PATH with CUDA libraries
  - Runs startup diagnostics (GPU status, network connectivity)
  - Configured as `ExecStart=` in all systemd services
  - **Critical for subprocess environment** - sets LD_LIBRARY_PATH before Python spawns runners
  
- **Environment**: `/home/bdeeley/exo/.venv/` (maxpower/theplague) or `/NVME/debian-exo/.venv/` (debian)
  - Python 3.13 with MLX 0.32.0 (or 0.31.2 on debian - **MISMATCH**)
  - CUDA 12 libraries via `pip install mlx-cuda-12`

---

## STOPPING & STARTING SERVICES

### Stop All Services
```bash
# Master
sudo systemctl stop exo.service

# Debian worker
ssh bdeeley@172.16.0.14 "sudo systemctl stop exo-remote-3090.service"

# Theplague worker
ssh bdeeley@172.16.0.175 "sudo systemctl stop exo.service"
```

### Start All Services
```bash
# Master
sudo systemctl start exo.service

# Debian worker
ssh bdeeley@172.16.0.14 "sudo systemctl start exo-remote-3090.service"

# Theplague worker
ssh bdeeley@172.16.0.175 "sudo systemctl start exo.service"
```

### Restart with Fresh Logs
```bash
# Stop all, clear central log, start all
ssh bdeeley@172.16.0.14 "sudo systemctl stop exo-remote-3090.service" && \
ssh bdeeley@172.16.0.175 "sudo systemctl stop exo.service" && \
sudo systemctl stop exo.service && \
sudo rm -f /BIGMIRROR/exo-cluster.log && \
sleep 3 && \
sudo systemctl start exo.service && \
ssh bdeeley@172.16.0.14 "sudo systemctl start exo-remote-3090.service" && \
ssh bdeeley@172.16.0.175 "sudo systemctl start exo.service" && \
sleep 5 && \
echo "✓ All services started"
```

---

## IMMEDIATE ACTION ITEMS FOR NEXT SESSION

### Issue: MLX Version Mismatch (CRITICAL - Blocks all progress)

**Step 1: Check MLX Availability**
```bash
# Check what versions are currently available/pinned
grep -i "mlx" /home/bdeeley/exo/pyproject.toml | head -20

# Check installed wheels on all nodes
echo "Maxpower:" && find /home/bdeeley/exo/.venv -name "mlx*.dist-info" | cut -d'/' -f9
echo "Debian:" && ssh bdeeley@172.16.0.14 "find /NVME/debian-exo/.venv -name 'mlx*.dist-info' | cut -d'/' -f9"
echo "Theplague:" && ssh bdeeley@172.16.0.175 "find /home/bdeeley/exo/.venv -name 'mlx*.dist-info' | cut -d'/' -f9"
```

**Step 2A: Upgrade Debian to 0.32.0 (if available)**
```bash
ssh bdeeley@172.16.0.14 << 'EOF'
cd /NVME/debian-exo
# Try to install matching version
./.venv/bin/python3 -m pip install --upgrade mlx==0.32.0 --no-cache-dir 2>&1 | tail -10
# OR use uv if pip not available
/home/bdeeley/.local/bin/uv pip install --upgrade mlx==0.32.0
# Clear cache
find /NVME/debian-exo -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
EOF
```

**Step 2B: Alternative - Rebuild Debian Environment**
```bash
# If versions incompatible, rebuild debian venv from scratch
ssh bdeeley@172.16.0.14 << 'EOF'
cd /NVME/debian-exo
sudo systemctl stop exo-remote-3090.service
rm -rf /NVME/debian-exo/.venv
python3.13 -m venv /NVME/debian-exo/.venv
/NVME/debian-exo/.venv/bin/python3 -m pip install -r /NVME/debian-exo/requirements.txt
# OR copy working venv from theplague
# scp -r bdeeley@172.16.0.175:/home/bdeeley/exo/.venv/lib/python3.13/site-packages/mlx* /NVME/debian-exo/.venv/lib/python3.13/site-packages/
EOF
```

**Step 3: Verify Version Match**
```bash
for node in maxpower debian theplague; do
  echo "$node:"
  case $node in
    maxpower) find /home/bdeeley/exo/.venv -name "mlx-*.dist-info" | xargs basename | cut -d'-' -f2 ;;
    debian) ssh bdeeley@172.16.0.14 "find /NVME/debian-exo/.venv -name 'mlx-*.dist-info' | xargs basename | cut -d'-' -f2" ;;
    theplague) ssh bdeeley@172.16.0.175 "find /home/bdeeley/exo/.venv -name 'mlx-*.dist-info' | xargs basename | cut -d'-' -f2" ;;
  esac
done
# Output should be identical across all nodes
```

**Step 4: Restart and Test**
```bash
# Restart all services
sudo systemctl restart exo.service
ssh bdeeley@172.16.0.14 "sudo systemctl restart exo-remote-3090.service"
ssh bdeeley@172.16.0.175 "sudo systemctl restart exo.service"
sleep 5

# Deploy fresh instance
curl -s -X POST http://localhost:52415/place_instance \
  -H "Content-Type: application/json" \
  -d '{"model_id": "mlx-community/Qwen2.5-72B-Instruct-4bit", "min_nodes": 3}' | python3 -m json.tool

# Monitor for runner success
sleep 10
sudo journalctl -u exo.service -n 50 --no-pager | grep -E "RunnerReady|RunnerFailed|PLACEMENT"
```

**Step 5: Success Criteria**
- All 3 nodes report same MLX version
- Master logs show: `"✅ PLACEMENT COMPLETE: <instance_id> placed on 3 nodes"`
- Plan cycles show: `Instances: 1 | Local runners: 1 | Global runners: 3 | Tasks: <N>`
- At least one runner transitions to `RunnerReady` state (check logs)
- No "undefined symbol" errors in debian logs

---

## GIT COMMIT

When ready to commit progress:
```bash
cd /home/bdeeley/test
git add -A
git commit -m "Status: MLX version mismatch identified, min_nodes fix verified

- Instance creation now works with min_nodes: 3 (was blocked by min_nodes: 4)
- Root cause: cluster has 3 nodes, not 4 (placement.py line 122-130)
- Placement algorithm verified functional: placement succeeds, shard distribution correct
- Wrapper script LD_LIBRARY_PATH fixed: added cuda_runtime/lib and cuda_nvrtc/lib paths
- Symlink structure verified: /NVME symlinks working on debian
- BLOCKING ISSUE: MLX version mismatch (debian 0.31.2 vs maxpower/theplague 0.32.0)
  - Causes runner ImportError: undefined symbol in mlx/core.so
  - Blocks runner execution, prevents model loading
- Next: Resolve MLX versions (upgrade debian or rebuild environment)"

git log --oneline -5  # Verify commit
```

---

## CLUSTER QUICK REFERENCE

### Useful Commands
```bash
# View cluster status
curl http://localhost:52415/state | python3 -m json.tool | grep -E '"instances"|"runners"' -A3

# Clear old event logs before fresh deployment
ssh bdeeley@172.16.0.14 "rm -rf /NVME/debian-exo/event_log.bin*"
ssh bdeeley@172.16.0.175 "rm -rf /home/bdeeley/exo/event_log.bin*"
rm -rf /home/bdeeley/exo/event_log.bin*

# Monitor node connectivity
for node in 172.16.0.174 172.16.0.14 172.16.0.175; do
  echo -n "$node: "
  curl -s http://$node:52415/node_id 2>&1 | python3 -c "import sys,json; print(json.load(sys.stdin)['node_id'][:20])" || echo "unreachable"
done

# Check available GPU memory
nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv,noheader

# SSH to nodes
ssh bdeeley@172.16.0.14    # debian
ssh bdeeley@172.16.0.175   # theplague
# maxpower: local terminal
```

### Critical Path to Success
1. ✅ Fix min_nodes: 4 → 3 (DONE - instance creation works)
2. ❌ Fix MLX version mismatch (IN PROGRESS - needed before next step)
3. ⏳ Verify runners reach RunnerReady state (waiting on #2)
4. ⏳ Monitor model download completion (waiting on #2)
5. ⏳ Test inference on loaded model (waiting on #2-4)

---

**Document prepared for handoff to next LLM session**  
**All absolute paths, IPs, and service names verified as of June 3, 2026 19:10 CDT**
