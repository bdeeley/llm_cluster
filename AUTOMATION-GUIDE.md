# EXO Cluster Automation & Troubleshooting Guide

Complete standardized automation for multi-node EXO cluster setup, deployment, and troubleshooting.

## Quick Start

### 1. Deploy standardized configuration to all nodes
```bash
cd /home/bdeeley/test
bash deploy-all-nodes.sh
```

### 2. Start the cluster
```bash
bash cluster-control.sh start
```

### 3. Check cluster status
```bash
bash cluster-control.sh status
```

### 4. View recent logs
```bash
bash cluster-control.sh logs
```

---

## Available Scripts

### `node-config.env`
**Standardized configuration file for the entire cluster**

Defines:
- Cluster topology (all nodes and IPs)
- Standard paths (same on all nodes)
- Environment variables (CUDA, HF_TOKEN, etc.)
- GPU configuration per node
- Bootstrap peer list
- Service names

**Usage:** Sourced by all other scripts automatically

---

### `setup-node.sh`
**Standardize a single node's configuration**

Creates:
- Standardized directory structure
- Generates systemd service file
- Registers service with systemd
- Validates environment

**Usage:**
```bash
# Setup local master
bash setup-node.sh master master

# Setup local worker
bash setup-node.sh worker worker

# Setup remote node (run on remote or via SSH)
bash setup-node.sh remote theplague
```

**What it does:**
1. Validates paths and NVIDIA libraries
2. Creates cache/log directories
3. Generates systemd service file with standardized config
4. Installs service file
5. Reloads systemd daemon

---

### `deploy-all-nodes.sh`
**Deploy standardized configuration to ALL nodes at once**

Automatically:
1. Sets up local master
2. Sets up local worker
3. Copies config files to all remote nodes
4. Runs setup on each remote node

**Usage:**
```bash
bash deploy-all-nodes.sh

# Skip remote nodes (local only)
bash deploy-all-nodes.sh --skip-remotes

# Skip validation (if you're confident in setup)
bash deploy-all-nodes.sh --skip-validation
```

**Output:** Summary of deployment with next steps

---

### `test-single-node.sh`
**Troubleshoot individual nodes in isolation**

Tests a single node by:
1. Stopping all services
2. Clearing caches
3. Starting service fresh
4. Checking service status
5. Validating API connectivity
6. Viewing detailed logs with debug markers
7. Checking environment variables

**Usage:**
```bash
# Test local master
bash test-single-node.sh master

# Test local worker
bash test-single-node.sh worker

# Test remote node
bash test-single-node.sh theplague
bash test-single-node.sh debian
```

**Logs location:** `/tmp/exo-single-node-test/`

**What to look for:**
- Check for `🚀 BOOTSTRAP ENTRYPOINT STARTED` marker
- Look for `🔧 SETTING UP LIBRARY PATHS` section
- Should find all 6 NVIDIA library paths
- Should see `✓ Successfully imported MLX patches`

---

### `cluster-control.sh`
**Manage entire cluster startup/shutdown**

Commands:
- `start` - Start all nodes in correct order
- `stop` - Stop all nodes gracefully
- `restart` - Restart entire cluster
- `status` - Check health of all nodes and APIs
- `logs` - View recent logs from master and worker

**Usage:**
```bash
# Start cluster (remotes first, then master, then worker)
bash cluster-control.sh start

# Check cluster health
bash cluster-control.sh status

# Stop cluster
bash cluster-control.sh stop

# Restart everything
bash cluster-control.sh restart

# View logs
bash cluster-control.sh logs
```

**Startup sequence:**
1. Remote nodes start (discover each other via bootstrap peers)
2. Wait 15 seconds for peer discovery
3. Local master starts
4. Local worker starts
5. Wait 30 seconds for topology stabilization
6. Display final topology

---

### `cluster-diagnose.sh`
**Comprehensive diagnostics for troubleshooting**

Collects from each node:
- System information (OS, hostname, IPs)
- Directory structure
- Python environment
- NVIDIA libraries and GPU status
- Environment variables
- Service status
- Recent logs (with filters for key events)

**Usage:**
```bash
# Diagnose all nodes
bash cluster-diagnose.sh all

# Diagnose specific node
bash cluster-diagnose.sh master
bash cluster-diagnose.sh worker
bash cluster-diagnose.sh theplague

# Default to 'all'
bash cluster-diagnose.sh
```

**Output:** Saves detailed logs to `/tmp/exo-diagnostics-{TIMESTAMP}/`

---

## Standardized Directory Structure

All nodes have identical structure:

```
/home/bdeeley/exo/                      # Main exo repo
/home/bdeeley/exo/.venv/                # Virtual environment
/home/bdeeley/.cache/exo-master/        # Master cache (local)
/home/bdeeley/.cache/exo-worker/        # Worker cache (local)
/home/bdeeley/.cache/exo-{NODE_NAME}/   # Remote node caches
/home/bdeeley/.local/share/exo-master/  # Master state (local)
/home/bdeeley/.local/share/exo-worker/  # Worker state (local)
/home/bdeeley/.local/share/exo-{NODE_NAME}/  # Remote node state
```

**Note:** Each instance (master, worker, remote) has isolated cache and state directories, preventing conflicts.

---

## Standardized Environment Variables

**All nodes have these environment variables in systemd service:**

```
CUDA_HOME=/usr
CUDA_PATH=/usr
CPATH=/usr/include
CPLUS_INCLUDE_PATH=/usr/include
LD_LIBRARY_PATH=/home/bdeeley/exo/.venv/lib/python3.13/site-packages/nvidia/{cublas,cuda_nvrtc,cudnn,cufft,nccl,nvjitlink}/lib
HF_TOKEN=<shared across all nodes>
RUST_LOG=info
```

**Per-node GPU configuration:**

```
Master:  CUDA_VISIBLE_DEVICES=0,1 OVERRIDE_MEMORY_MB=24000
Worker:  CUDA_VISIBLE_DEVICES=0  OVERRIDE_MEMORY_MB=20000
Remotes: CUDA_VISIBLE_DEVICES=0  OVERRIDE_MEMORY_MB=20000
```

---

## Standardized Bootstrap Peer Configuration

All nodes bootstrap from the same peer list:

```
/ip4/172.16.0.174/tcp/5678   # Master node
/ip4/172.16.0.174/tcp/5680   # Worker node
/ip4/172.16.0.175/tcp/5679   # Theplague (remote)
/ip4/172.16.0.14/tcp/5679    # Debian (remote)
```

This ensures all nodes can discover each other regardless of which starts first.

---

## Verbose Logging Features

### Bootstrap Verbose Logging
The `bootstrap.py` has enhanced logging that shows:

```
🚀 BOOTSTRAP ENTRYPOINT STARTED       # Process started
  Python version, venv, working dir   # Context info
🔧 SETTING UP LIBRARY PATHS           # Environment setup
  ✓ Found 6 NVIDIA libraries          # Library paths
  ✓ Set LD_LIBRARY_PATH              # Environment configured
📦 LOADING DEPENDENCIES               # Import phase
  ✓ Imported Runner class            # Success markers
🎨 IMAGE MODEL DETECTED or 📝 TEXT MODEL
  ✓ Successfully imported MLX patches # MLX import
🏃 CREATING RUNNER INSTANCE           # Execution phase
  ✓ Runner instance created          # Ready
🎯 STARTING RUNNER MAIN LOOP          # Running
🏁 SHUTTING DOWN RUNNER               # Cleanup
👋 BOOTSTRAP ENTRYPOINT EXITING       # Done
```

Look for these markers in logs to track execution flow.

---

## Typical Workflow

### Initial Setup
```bash
# 1. Deploy standardized config to all nodes
cd /home/bdeeley/test
bash deploy-all-nodes.sh

# 2. Start cluster
bash cluster-control.sh start

# 3. Verify status
bash cluster-control.sh status
```

### Testing Individual Nodes
```bash
# If cluster doesn't start, test nodes individually
bash test-single-node.sh master
bash test-single-node.sh worker
bash test-single-node.sh theplague
bash test-single-node.sh debian
```

### Troubleshooting Issues
```bash
# Get comprehensive diagnostics
bash cluster-diagnose.sh all

# Or specific node
bash cluster-diagnose.sh theplague

# Then check logs
tail -f /tmp/exo-diagnostics-*/theplague.log
```

### Redeploying After Changes
```bash
# If you change bootstrap.py or config:
bash deploy-all-nodes.sh
bash cluster-control.sh restart
bash cluster-diagnose.sh all
```

---

## Common Issues & Solutions

### Issue: Remote nodes not connecting to master
**Check:**
1. Bootstrap peers configured correctly: `grep BOOTSTRAP_PEERS node-config.env`
2. Remote services started: `bash cluster-control.sh status`
3. Logs show peer discovery: `bash cluster-diagnose.sh all`

**Fix:** Update bootstrap peers in `node-config.env`, then:
```bash
bash deploy-all-nodes.sh
bash cluster-control.sh restart
```

### Issue: MLX import failing on remote nodes
**Check:**
1. NVIDIA libraries present: Look for `Found X/6 NVIDIA library paths` in logs
2. LD_LIBRARY_PATH set correctly: Check service file environment
3. Python venv intact: Verify `/home/bdeeley/exo/.venv/bin/python3` works

**Fix:**
```bash
# On remote node:
bash test-single-node.sh <NODE_NAME>

# Look at detailed logs:
tail -f /tmp/exo-single-node-test/<NODE_NAME>.log
```

### Issue: Services starting but not forming topology
**Check:**
1. All nodes can ping each other
2. Ports 5678, 5680, 5679 are open
3. Bootstrap peers are reachable

**Fix:** Check firewall and network configuration, then:
```bash
bash cluster-control.sh restart
bash cluster-diagnose.sh all
```

---

## Manual Testing After Automation

Once cluster is running:

### Test single-node inference
```bash
curl -X POST "http://localhost:52415/place_instance" \
  -H "Content-Type: application/json" \
  -d '{"model_id": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit", "instance_id": "test-1node", "min_nodes": 1}'
```

### Test 4-node distributed inference
```bash
curl -X POST "http://localhost:52415/place_instance" \
  -H "Content-Type: application/json" \
  -d '{"model_id": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit", "instance_id": "test-4node", "min_nodes": 4}'
```

### Run inference
```bash
curl -X POST "http://localhost:52415/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit",
    "messages": [{"role": "user", "content": "What is distributed computing?"}],
    "max_tokens": 50
  }' | jq '.choices[0].message.content'
```

---

## Logs Location

All logs are standardized by node type:

**Local Master:**
```
/home/bdeeley/.cache/exo-master/exo_log/
```

**Local Worker:**
```
/home/bdeeley/.cache/exo-worker/exo_log/
```

**Remote Nodes:**
```
/home/bdeeley/.cache/exo-{NODE_NAME}/exo_log/
```

**Systemd Logs:**
```bash
# Master
sudo journalctl -u exo.service -f

# Worker
sudo journalctl -u exo-worker.service -f

# Remote (via SSH)
ssh bdeeley@theplague "sudo journalctl -u exo.service -f"
```

---

## Configuration File Reference

See `node-config.env` for:
- All cluster topology definitions
- Standard paths
- Environment variables
- GPU configurations
- Bootstrap peer list
- Validation functions

Edit this file if you need to:
- Change IP addresses
- Add/remove nodes
- Modify GPU assignments
- Update HuggingFace token
- Change log locations

**After editing:**
```bash
bash deploy-all-nodes.sh
bash cluster-control.sh restart
```

---

## Summary

This automation framework provides:

✅ **Standardized Setup** - All nodes configured identically
✅ **Easy Deployment** - Single command to setup entire cluster
✅ **Single-Node Testing** - Test each node independently
✅ **Cluster Control** - Start/stop/restart entire cluster
✅ **Comprehensive Diagnostics** - Troubleshoot any issues
✅ **Verbose Logging** - Track execution flow at every step
✅ **Idempotent** - Safe to run scripts multiple times
✅ **Automation-Ready** - All scripts are bash-based for easy integration

**Get started:** `bash deploy-all-nodes.sh && bash cluster-control.sh start`
