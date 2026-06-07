# EXO Cluster Automation Guide

Date: June 7, 2026

This runbook reflects the consolidated operational workflow for this repo.

## 1. Preconditions
- SSH from controller to all nodes works without interaction.
- Required services are installed:
  - maxpower: exo.service, exo-worker.service
  - theplague: exo.service
  - debian: exo-remote-3090.service
- CUDA include/env drop-ins are already present.

## 2. Start Cluster
Use the canonical helper:

```bash
cd /Users/bdeeley/cluster/llm_cluster
./cluster-control.sh start
./cluster-control.sh status
```

If startup ordering must be manual, use:
1. Start remotes (theplague + debian).
2. Start maxpower master + worker.
3. Wait until /state reports nodes=4 and connections are converged.

## 3. Health Validation
```bash
./cluster-diagnose.sh all
curl -s http://localhost:52415/state | jq '{nodes:(.nodeIdentities|length), conns:(.topology.connections|keys|length), instances:(.instances|length), runners:(.runners|length)}'
```

GPU quick view:
```bash
ssh bdeeley@172.16.0.174 'nvidia-smi --query-gpu=index,name,memory.used,utilization.gpu --format=csv,noheader'
ssh bdeeley@172.16.0.175 'nvidia-smi --query-gpu=index,name,memory.used,utilization.gpu --format=csv,noheader'
ssh bdeeley@172.16.0.14  'nvidia-smi --query-gpu=index,name,memory.used,utilization.gpu --format=csv,noheader'
```

## 4. Placement Patterns
### 4.1 Pipeline placement (memory spread)
```bash
curl -s -X POST http://localhost:52415/place_instance \
  -H 'Content-Type: application/json' \
  -d '{"model_id":"mlx-community/Qwen2.5-72B-Instruct-4bit","min_nodes":4}' | jq .
```

### 4.2 Tensor placement (true distributed compute attempt)
Only valid for supportsTensor=true models.
```bash
curl -s -X POST http://localhost:52415/place_instance \
  -H 'Content-Type: application/json' \
  -d '{"model_id":"<tensor-capable-model>","sharding":"Tensor","instance_meta":"MlxRing","min_nodes":4}' | jq .
```

Validate whether tensor sharding was actually selected:
```bash
curl -s http://localhost:52415/instance/previews?model_id=<model>&sharding=Tensor&instance_meta=MlxRing&min_nodes=4 | jq .
```

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
ssh bdeeley@172.16.0.174 'sudo journalctl -u exo.service -n 200 --no-pager'
ssh bdeeley@172.16.0.175 'sudo journalctl -u exo.service -n 200 --no-pager'
ssh bdeeley@172.16.0.14  'sudo journalctl -u exo-remote-3090.service -n 200 --no-pager'
```

## 7. Stop Cluster
```bash
./cluster-control.sh stop
./cluster-control.sh status
```

If a unit sticks in deactivating, stop+kill on that host and re-check state.

## 8. Resume Focus (next session)
1. Complete uniform 10 Gb interconnect for all participating nodes.
2. Re-test with supportsTensor=true model and explicit Tensor sharding.
3. Confirm distributed compute using per-second process-level GPU sampling.
