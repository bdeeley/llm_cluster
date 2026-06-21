# EXO Cluster Automation Guide

Date: June 21, 2026

This runbook reflects the consolidated operational workflow for this repo.

## Closeout Execution Profile (Current)
Use this when the priority is to finalize the 48 GB pool and move on to infra expansion.

1. Primary acceptance (VRAM-first):
- `./distinct-ip-rank.sh restart && ./distinct-ip-rank.sh gate mlx-community/Qwen2.5-7B-Instruct-4bit 3`
- Require PASS through Gate E.

2. Deferred acceptance (compute parity):
- Run tensor-capable model validation only after network/node upgrade workstream milestones.
- Track separately as optimization, not as a blocker for closeout.

## 0. Bootstrap Gate (theplague)
Complete this before cluster startup:
1. exo checkout exists and is up to date on theplague.
2. uv/venv dependencies installed on theplague.
3. CUDA header include paths available to exo.service runtime.
4. `/BIGMIRROR` and `/NVME` are mounted and persistent on reboot.
5. exo.service is installed on theplague and passes `systemctl status`.

## 1. Preconditions
- SSH from controller to all nodes works without interaction.
- Required services are installed:
  - maxpower: exo.service, exo-worker.service
  - theplague: exo.service
- debian is decommissioned for current phase.
- CUDA include/env drop-ins are already present.

## 2. Start Cluster
Use the canonical helper:

```bash
cd /Users/bdeeley/cluster/llm_cluster
./cluster-control.sh start
./cluster-control.sh status
```

If startup ordering must be manual, use:
1. Start remotes (theplague only in current phase).
2. Start maxpower master + worker.
3. Wait until /state reports expected active nodes and connections are converged.

## 3. Health Validation
```bash
./cluster-diagnose.sh all
curl -s http://localhost:52415/state | jq '{nodes:(.nodeIdentities|length), conns:(.topology.connections|keys|length), instances:(.instances|length), runners:(.runners|length)}'
```

GPU quick view:
```bash
ssh bdeeley@172.16.0.28 'nvidia-smi --query-gpu=index,name,memory.used,utilization.gpu --format=csv,noheader'
ssh bdeeley@172.16.0.29 'nvidia-smi --query-gpu=index,name,memory.used,utilization.gpu --format=csv,noheader'
```

## 4. Placement Patterns
### 4.1 Pipeline placement (memory spread)
```bash
curl -s -X POST http://localhost:52415/place_instance \
  -H 'Content-Type: application/json' \
  -d '{"model_id":"mlx-community/Qwen2.5-72B-Instruct-4bit","min_nodes":3}' | jq .
```

### 4.2 Tensor placement (true distributed compute attempt)
Only valid for supportsTensor=true models.
```bash
curl -s -X POST http://localhost:52415/place_instance \
  -H 'Content-Type: application/json' \
  -d '{"model_id":"<tensor-capable-model>","sharding":"Tensor","instance_meta":"MlxRing","min_nodes":3}' | jq .
```

Validate whether tensor sharding was actually selected:
```bash
curl -s http://localhost:52415/instance/previews?model_id=<model>&sharding=Tensor&instance_meta=MlxRing&min_nodes=3 | jq .
```

### 4.3 Model-fit discovery for current pool (24+12+12 GB)
Use this process to find a candidate that fits current active VRAM and is viable for tensor-path testing.

Candidate shortlist loop (edit list as needed):
```bash
for m in \
  mlx-community/Qwen2.5-32B-Instruct-4bit \
  mlx-community/Qwen2.5-14B-Instruct-4bit \
  mlx-community/Mistral-Small-24B-Instruct-2501-4bit
do
  echo "=== $m ==="
  curl -s "http://localhost:52415/instance/previews?model_id=${m}&sharding=Tensor&instance_meta=MlxRing&min_nodes=3" | jq .
done
```

Promotion rule:
1. Preview/placement succeeds at `min_nodes=3`.
2. Model can be placed with explicit `sharding=Tensor`.
3. Under sustained payload, all three active GPUs show non-trivial SM utilization.

## 5. Payload Test
```bash
curl -sS -X POST http://localhost:52415/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<model>","messages":[{"role":"user","content":"Reply with OK"}],"max_tokens":16,"temperature":0}' | jq .
```

## 6. Logging
Primary live monitor:
```bash
./monitor-logs.sh
```

Targeted logs:
```bash
ssh bdeeley@172.16.0.28 'sudo journalctl -u exo.service -n 200 --no-pager'
ssh bdeeley@172.16.0.29 'sudo journalctl -u exo.service -n 200 --no-pager'
```

## 7. Stop Cluster
```bash
./cluster-control.sh stop
./cluster-control.sh status
```

If a unit sticks in deactivating, stop+kill on that host and re-check state.

## 8. Resume Focus (next session)
1. Run mixed-fabric baseline now (2.5/5/10 Gb), then repeat after the 4x10 Gb switch/NIC upgrade.
2. Re-test with supportsTensor=true model and explicit Tensor sharding.
3. Confirm distributed compute using per-second process-level GPU sampling.
