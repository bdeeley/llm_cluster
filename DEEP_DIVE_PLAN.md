# DEEP DIVE PLAN: Get 4-Node Exo Cluster With Model Working
## Systematic Debugging of Model Loading & Runner Execution

---

## STATUS SUMMARY

### What's Working ✅
- **Cluster Topology**: 4 nodes can communicate (libp2p mesh established)
- **APIs**: All 4 node REST APIs are responsive
- **Placement Requests**: Master accepts `place_instance` API calls
- **Services**: All 4 systemd services start and stay running

### What's BROKEN ❌
- **Model Loading**: Models accepted but NEVER load to VRAM
- **Runner Execution**: Runners created but appear to fail silently
- **Inference**: /v1/chat/completions endpoint hangs indefinitely
- **No Error Messages**: Placement succeeds but produces no model weights on GPU

---

## ROOT CAUSE HYPOTHESIS

The exo v1 placement algorithm accepts placement requests and appears to acknowledge them, but **the actual runner process never successfully loads the model binary into GPU VRAM**. 

**Possible causes:**
1. Runner process exits before calling model loading
2. Model loading call fails silently (no error logging)
3. Symlink to model file not being followed correctly
4. CUDA/GPU initialization fails in runner context
5. Sharding metadata incorrect (causes wrong layer splits)
6. Runner-to-Master communication broken (can't report status)

---

## SYSTEMATIC DEBUG PLAN

### PHASE 1: Verify Model Accessibility (15 min)
**Goal**: Confirm model files are readable from runner context

```bash
# 1.1 Check symlinks exist on all nodes
echo "Master:"; ls -lh ~/.local/share/exo/models/ | grep Llama
ssh bdeeley@172.16.0.175 'echo "Theplague:"; ls -lh ~/.local/share/exo/models/ | grep Llama'
ssh bdeeley@172.16.0.14 'echo "Debian:"; ls -lh ~/.local/share/exo/models/ | grep Llama'

# 1.2 Check actual model files exist (follow symlinks)
file ~/.local/share/exo/models/mlx-community--Llama-3.1-Nemotron-Nano-4B-v1.1-8bit/

# 1.3 Check file permissions (must be readable as bdeeley user)
stat ~/.local/share/exo/models/mlx-community--Llama-3.1-Nemotron-Nano-4B-v1.1-8bit/

# 1.4 Verify model can be loaded by simple Python script
python3 << 'PYEOF'
import os
model_dir = os.path.expanduser('~/.local/share/exo/models/mlx-community--Llama-3.1-Nemotron-Nano-4B-v1.1-8bit/')
if os.path.exists(model_dir):
    print(f"✓ Model directory exists: {model_dir}")
    files = os.listdir(model_dir)
    print(f"  Contains {len(files)} files/dirs")
    for f in files[:5]:
        print(f"    - {f}")
else:
    print(f"✗ Model directory NOT found")
PYEOF
```

**Expected**: Model files exist and are accessible

---

### PHASE 2: Trace Placement Request Through Master (20 min)
**Goal**: See exactly what Master does with placement request

```bash
# 2.1 Clear Master logs
sudo journalctl --vacuum-time=1s -u exo.service

# 2.2 Make a single placement request and capture logs
INST_ID="debug-$(date +%s)"
curl -s -X POST http://localhost:52415/place_instance \
  -H "Content-Type: application/json" \
  -d '{"model_id": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit", "instance_id": "'$INST_ID'", "min_nodes": 1}' \
  | jq '.command_id' | tee /tmp/cmd_id.txt

sleep 2

# 2.3 Search logs for placement algorithm execution
sudo journalctl -u exo.service --since "5 minutes ago" --no-pager | grep -A 20 "PlaceInstance"

# 2.4 Look for shard assignment
sudo journalctl -u exo.service --since "5 minutes ago" --no-pager | grep -i "shard\|pipeline\|assign"

# 2.5 Look for runner creation
sudo journalctl -u exo.service --since "5 minutes ago" --no-pager | grep -i "runner\|create"

# 2.6 Look for errors/exceptions
sudo journalctl -u exo.service --since "5 minutes ago" --no-pager | grep -i "error\|exception\|fail"
```

**Expected**: See "PlaceInstance" acknowledged + Shards assigned + Runners created

**If NOT found**: Placement algorithm might be exiting early without error

---

### PHASE 3: Check Runner Process Existence (15 min)
**Goal**: Verify runners are actually spawned and what state they're in

```bash
# 3.1 Watch for runner processes during placement
# Terminal 1:
watch -n 1 'ps aux | grep exo | grep -v grep'

# Terminal 2:
INST_ID="runner-test-$(date +%s)"
curl -s -X POST http://localhost:52415/place_instance \
  -H "Content-Type: application/json" \
  -d '{"model_id": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit", "instance_id": "'$INST_ID'", "min_nodes": 1}' | jq '.'

# 3.2 Check runner log files
ls -lh ~/.local/share/exo/runner_logs/ 2>/dev/null || echo "No runner logs found"

# 3.3 Check runner state files
ls -lh ~/.local/share/exo/runners/ 2>/dev/null || echo "No runner state found"
```

**Expected**: Runner process visible for ~5-30 seconds, then exits cleanly or with error

**If NOT found**: Runners not being spawned at all

---

### PHASE 4: Check Instance/Runner State in Master API (10 min)
**Goal**: See if Master knows about the runners it created

```bash
# 4.1 Check instances endpoint
curl -s http://localhost:52415/instances | jq '.' | head -50

# 4.2 Check state endpoint for running_instances
curl -s http://localhost:52415/state | jq '.nodeIdentities | to_entries | map({node_id: .key, running_instances: .value.running_instances})'

# 4.3 Check if runners are listed
curl -s http://localhost:52415/state | jq '.runners' | head -20

# 4.4 Look for placement metadata
curl -s http://localhost:52415/state | jq '.placements' 2>/dev/null | head -20
```

**Expected**: See active instances, runners, and placement metadata

**If empty**: Instances created but not tracked, or immediately deleted

---

### PHASE 5: Enable Debug Logging in Exo (15 min)
**Goal**: Get verbose output from placement algorithm

```bash
# 5.1 Check if exo supports RUST_LOG
sudo systemctl stop exo.service
sleep 2

# 5.2 Edit service file to add debug logging
sudo tee /etc/systemd/system/exo.service.d/debug.conf << 'EOF'
[Service]
Environment="RUST_LOG=debug"
Environment="EXOLOG=debug"
EOF

# 5.3 Reload and start
sudo systemctl daemon-reload
sudo systemctl start exo.service

# 5.4 Wait for startup
sleep 5

# 5.5 Make placement request
INST_ID="logged-$(date +%s)"
curl -s -X POST http://localhost:52415/place_instance \
  -H "Content-Type: application/json" \
  -d '{"model_id": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit", "instance_id": "'$INST_ID'", "min_nodes": 1}' | jq '.'

sleep 3

# 5.6 Check logs for debug output
sudo journalctl -u exo.service -n 100 --no-pager | tail -50
```

**Expected**: Verbose debug output showing exactly where placement fails

---

### PHASE 6: Test Runner Directly (20 min)
**Goal**: Try to create and run a runner manually to isolate issues

```bash
# 6.1 Check if exo has a runner CLI command
/home/bdeeley/.local/bin/uv run exo --help | grep -i runner

# 6.2 Try to manually initialize a runner with a model
# (This depends on exo's internal CLI - check source code)

# 6.3 If manual runner test fails, check:
#   - CUDA visibility: nvidia-smi
#   - Model file readability: python3 -c "import os; print(os.access('...', os.R_OK))"
#   - Python environment: /home/bdeeley/exo/.venv/bin/python --version
```

**Expected**: If manual runner succeeds, issue is in placement orchestration. If it fails, issue is in runner code itself.

---

### PHASE 7: Check Exo Source Code (Depends on findings)
**Goal**: Identify exact code path where runner creation/model loading fails

**Key files to inspect:**
```
~/exo/src/exo/master/placement.py       # Placement algorithm
~/exo/src/exo/worker/runner.py          # Runner execution
~/exo/src/exo/api/inference.py          # Inference endpoint
```

**Look for:**
- Try/except blocks that swallow errors
- Model loading code that returns early
- Subprocess spawn calls (how runners are created)
- CUDA initialization code

---

## EXECUTION CHECKLIST

- [ ] Phase 1: Model accessibility verified
- [ ] Phase 2: Placement request traced in logs
- [ ] Phase 3: Runner processes confirmed/not found
- [ ] Phase 4: Master API state checked
- [ ] Phase 5: Debug logging enabled and reviewed
- [ ] Phase 6: Manual runner test attempted
- [ ] Phase 7: Source code inspection (if needed)

---

## QUICK START COMMANDS

```bash
# Reset cluster completely
bash /home/bdeeley/test/cluster/manage_cluster.sh cleanup

# Start fresh
bash /home/bdeeley/test/cluster/manage_cluster.sh start

# Run Phase 1 diagnostics
bash /home/bdeeley/test/cluster/debug-placement.sh phase1

# Monitor all 4 nodes simultaneously
watch -n 2 'echo "=== Master ==="; curl -s http://localhost:52415/state | jq ".nodeIdentities | length"; echo "=== Worker ==="; curl -s http://127.0.0.1:52416/state | jq ".nodeIdentities | length" 2>/dev/null || echo "N/A"; echo "=== Theplague ==="; curl -s http://172.16.0.175:52415/state | jq ".nodeIdentities | length" 2>/dev/null || echo "N/A"; echo "=== Debian ==="; curl -s http://172.16.0.14:52415/state | jq ".nodeIdentities | length" 2>/dev/null || echo "N/A"'
```

---

## SUCCESS CRITERIA

✅ Model loads: `nvidia-smi` shows 4.8GB+ VRAM used on at least one GPU  
✅ Inference responds: `/v1/chat/completions` returns tokens (not hangs)  
✅ Distributed: Model shards visible across multiple nodes (check via API)  
✅ Stable: Same placement works consistently without restarts
