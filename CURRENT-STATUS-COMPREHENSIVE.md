# EXO Cluster Current Status (Comprehensive)

Date: June 7, 2026
State: Paused intentionally after consolidation and shutdown

## Executive Checkpoint
- Cluster services are stopped on all nodes.
- Repository has been consolidated: legacy reports/scripts archived, active runbook simplified.
- Investigative conclusion is stable: current 72B target achieves VRAM distribution but not balanced decode compute.

## Final Service State at Pause
- maxpower (172.16.0.174)
  - exo.service: inactive
  - exo-worker.service: inactive
- theplague (172.16.0.175)
  - exo.service: stopped (inactive/failed state after stop)
- debian (172.16.0.14)
  - exo-remote-3090.service: stopped (inactive/failed state after stop)

## What Was Proven
1. Topology can converge to 4 nodes with active runners and successful placement.
2. Qwen2.5-72B-Instruct-4bit loads shards into VRAM across all 4 GPUs.
3. Payload serving works from master API.
4. During sustained decode, high SM utilization remains concentrated on one GPU rank.

## Why Compute Was Not Evenly Distributed
1. Model capability gate:
- `mlx-community/Qwen2.5-72B-Instruct-4bit` reports `supportsTensor=false`.
- This blocks true tensor-parallel decode behavior for this model path.

2. Cluster constraints:
- Mixed GPU class/capability (including Quadro P6000 with older compute capability).
- Asymmetric link speeds during tests (2.5 Gb and 10 Gb mixed).
- Node software parity needs to be enforced before next deep run.

## Decision for Next Session
- Proceed with network uplift to uniform 10 Gb.
- Resume using a `supportsTensor=true` model.
- Request tensor explicitly:
  - `sharding=Tensor`
  - `instance_meta=MlxRing` first (jaccl only after suitable RDMA/all-to-all prerequisites are met)

## Next Session Success Criteria
1. All participating links run at 10 Gb full duplex.
2. Placement uses tensor-capable model with explicit Tensor sharding.
3. Under sustained decode load, each node shows non-trivial GPU SM utilization (not only VRAM residency).
4. Per-node sampling (`nvidia-smi pmon` at 1s cadence) confirms activity across all ranks during the same request window.
5. If any node remains mostly idle while others are saturated, capture logs/state and treat run as not meeting parity target.

## Resume Procedure
1. Start cluster:
```bash
cd /Users/bdeeley/cluster/llm_cluster
./cluster-control.sh start
./cluster-control.sh status
```

2. Validate topology/health:
```bash
./cluster-diagnose.sh all
curl -s http://localhost:52415/state | jq '{nodes:(.nodeIdentities|length), conns:(.topology.connections|keys|length), instances:(.instances|length), runners:(.runners|length)}'
```

3. Place tensor-capable model:
```bash
curl -s -X POST http://localhost:52415/place_instance \
  -H 'Content-Type: application/json' \
  -d '{"model_id":"<supportsTensor-model>","sharding":"Tensor","instance_meta":"MlxRing","min_nodes":4}' | jq .
```

4. Validate compute distribution under load:
- Run a long payload.
- Sample `nvidia-smi pmon` at 1s cadence on all nodes.
- Confirm non-trivial SM utilization on remote ranks, not only on one local GPU.

## Consolidation Notes
- Active docs are now:
  - `README.md`
  - `AUTOMATION-GUIDE.md`
  - `CURRENT-STATUS-COMPREHENSIVE.md`
  - `nodes/README.md`
- Legacy docs/scripts moved under:
  - `docs/archive/`
  - `scripts/archive/`
