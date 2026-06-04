# EXO Distributed LLM Cluster - 4 Node Configuration

**Status**: VERBOSE LOGGING INFRASTRUCTURE DEPLOYED  
**Date**: June 1, 2026 (19:30+ CDT)  
**Cluster Type**: EXO P2P distributed inference framework with libp2p networking

## LATEST UPDATE: Complete Diagnostic Infrastructure Ready

**Full Logging Stack Deployed**:

### 1. Python-level Logging (Enhanced in 4 files)
- `plan.py`: State dump at every plan cycle, detailed runner tracking
- `main.py`: Task dispatch with entry/exit logging, detailed error context
- `runner.py`: Queue reception, task reader thread tracking, lifecycle events
- Task receiver: Detailed logging when tasks arrive from stream

### 2. systemd Service Logging
- All services configured with `StandardOutput=journal` and `StandardError=journal`
- `PYTHONUNBUFFERED=1` ensures real-time log output
- `SyslogIdentifier` tags for easy filtering
- Enhanced logging on: exo.service, exo-worker.service

### 3. Network Diagnostics
- `tcpdump` installed on all 4 nodes
- Ready to capture libp2p traffic (ports 5678, 5679, 5680)
- Captures API traffic (ports 52415, 52416)

### 4. Monitoring & Aggregation Tools
- `view-logs-realtime.sh`: Colored log viewer from all nodes
- `capture-network.sh`: tcpdump orchestration across all nodes
- `monitor-logs.sh`: Real-time filtering for diagnostic keywords
- `run-diagnostic-test.sh`: **MAIN TEST SCRIPT** - Automated full diagnostics

### Diagnostic Log Tags
- `[PLAN CYCLE START]` = Planning cycle in master
- `[TASK DISPATCH ENTRY]` = Task about to be sent from master
- `[TASK DISPATCH SUCCESS]` = Task successfully sent
- `[TASK DISPATCH ERROR]` = Task dispatch failed (instance/runner not found)
- `[TASK DISPATCH EXCEPTION]` = Unexpected error during dispatch
- `[RUNNER QUEUE]` = Task received by runner queue
- `[RUNNER DISPATCH]` = Task being handled by runner
- `[RANK N]` = Distributed model initialization at rank N
- `[TASK READER]` = Task stream events
- `[RUNNER CLEANUP]` = Runner shutdown

## Running the Diagnostic Test

```bash
cd /home/bdeeley/test
bash run-diagnostic-test.sh
```

This script:
1. Stops all services and clears event logs (fresh state)
2. Starts cluster with enhanced logging enabled
3. Verifies 4-node topology formation
4. Captures network traffic with tcpdump
5. Sends 4-node model placement request
6. Monitors runner initialization with 120s timeout
7. Collects all logs from all 4 nodes
8. Saves results to `/tmp/exo-test-results-<timestamp>/`

After test, analyze results:
```bash
RESULTS_DIR=$(ls -td /tmp/exo-test-results-* | head -1)
grep '[TASK DISPATCH]' $RESULTS_DIR/*.txt
grep '[RUNNER' $RESULTS_DIR/*.txt
grep '[RANK' $RESULTS_DIR/*.txt
grep 'ERROR\|TIMEOUT' $RESULTS_DIR/*.txt
```

## Manual Log Monitoring Tools

### Real-Time Log Viewer (All Nodes)
```bash
bash view-logs-realtime.sh
```
Shows last 20 lines from each node with color-coded output for diagnostics.

### Continuous Network Capture
```bash
bash capture-network.sh 60
```
Captures 60 seconds of network traffic, saves to `/tmp/exo-network-captures/`

### Monitor Live Logs with Filtering
```bash
bash monitor-logs.sh
```
Continuously monitors and filters for all `[TASK DISPATCH]`, `[RUNNER]`, `[RANK]` messages.

## Quick Reference

### Cluster Management
```bash
# Start cluster
cd /home/bdeeley/test && bash cluster-control.sh start

# Stop cluster
bash cluster-control.sh stop

# Check cluster status
curl -s http://localhost:52415/state | jq '.nodeIdentities | length'

# View master logs
sudo journalctl -u exo.service -f

# View worker logs
sudo journalctl -u exo-worker.service -f

# View remote node logs
ssh theplague 'sudo journalctl -u exo.service -f'
ssh debian 'sudo journalctl -u exo.service -f'
```

### Model Testing
```bash
# Place 4-node model
curl -s -X POST "http://localhost:52415/place_instance" \
  -H "Content-Type: application/json" \
  -d '{
    "model_id": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit",
    "instance_id": "test-'$(date +%s)'",
    "min_nodes": 4
  }'

# Monitor runners reaching ready state
while true; do
  curl -s http://localhost:52415/state | jq '[.runners[] | select(. | keys[0] == "RunnerReady")] | length'
  sleep 1
done

# Run inference
curl -s -X POST "http://localhost:52415/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 50
  }' | jq '.choices[0].message.content'
```

## Cluster Architecture

### Hardware Configuration
| Node | Hardware | Role | CUDA Status |
|------|----------|------|-------------|
| maxpower | RTX 3060 (12GB) + Quadro P6000 (24GB) | Master | ✓ Both working |
| theplague (172.16.0.175) | RTX 4090 (24GB) | Remote | ✓ Working |
| debian (172.16.0.14) | RTX 3090 (24GB) | Remote | ✓ Working |
| maxpower-worker | GPU0 management | Worker | ✓ Working |

**Total VRAM**: 84 GB (72 GB CUDA-capable)

### Network Topology
- libp2p P2P networking with Raft consensus
- Bootstrap peers: /ip4/172.16.0.174/tcp/{5678,5680}, /ip4/172.16.0.175/tcp/5679, /ip4/172.16.0.14/tcp/5679
- Master API: http://localhost:52415
- Worker API: http://localhost:52416

## Files Modified in This Session

### Python Source Code
1. [plan.py](../exo/src/exo/worker/plan.py#L156-L180) - Added state dump logging
2. [main.py](../exo/src/exo/worker/main.py#L385-L416) - Enhanced task dispatch logging
3. [runner.py](../exo/src/exo/worker/runner/runner.py#L163-L210) - Task queue and reader logging

### systemd Services
1. `/etc/systemd/system/exo.service` - Added journal output configuration
2. `/etc/systemd/system/exo-worker.service` - Added journal output configuration

### Test Scripts (in this directory)
1. `run-diagnostic-test.sh` - Main automated test with full diagnostics
2. `view-logs-realtime.sh` - Real-time log viewer with color coding
3. `capture-network.sh` - Network packet capture orchestration
4. `monitor-logs.sh` - Continuous diagnostic message filtering

## Troubleshooting

### If runners don't reach RunnerReady after 120s
1. Check `/tmp/exo-test-results-*/master-logs.txt` for `[TASK DISPATCH ERROR]`
2. Check `/tmp/exo-test-results-*/worker-logs.txt` for `[RUNNER QUEUE]` messages
3. Run `bash view-logs-realtime.sh` to see live logs from all nodes
4. Check network: `tcpdump -i any port 5678 or port 5679`

### If network traffic is blocked
1. Verify firewall: `sudo ufw status` on all nodes
2. Check SSH connectivity: `ssh -v bdeeley@172.16.0.175`
3. Test libp2p ports: `nc -zv 172.16.0.175 5679`
4. Verify DNS: `nslookup theplague.deeleymotorsports.lan`

### If logs aren't appearing
1. Verify systemd is capturing: `sudo journalctl -u exo.service -n 10`
2. Check Python buffering: `echo $PYTHONUNBUFFERED` (should be 1)
3. Verify services running: `systemctl status exo.service exo-worker.service`
4. Restart with reload: `sudo systemctl daemon-reload && sudo systemctl restart exo.service`

## What's Working

- [x] 4-Node cluster topology formation
- [x] Worker node synchronization
- [x] Model distribution across nodes
- [x] All CUDA backends operational
- [x] Comprehensive logging infrastructure
- [x] Network diagnostics tools
- [x] Automated test script with full diagnostics
- [ ] **Next**: Run diagnostic test to identify remaining issues
