# EXO Cluster Current Status (Comprehensive)

Date: June 20, 2026
State: Paused intentionally after consolidation and shutdown

## Executive Checkpoint
- Cluster services are stopped on all nodes.
- Repository has been consolidated: legacy reports/scripts archived, active runbook simplified.
- Investigative conclusion is stable: current 72B target achieves VRAM distribution but not balanced decode compute.
- Topology changed since June 7: debian is decommissioned for now; thegibson is the active 10 Gb storage server; maxpower moved to 10 Gb with a new IP; theplague moved to 5 Gb with a new IP and requires full exo re-setup after OS format.

## Final Service State at Pause
- maxpower (IP updated in active scripts/docs)
  - exo.service: expected inactive until resume
  - exo-worker.service: expected inactive until resume
- theplague (IP changed; host reformatted)
  - exo.service: not ready; requires exo/bootstrap/systemd setup
- debian
  - decommissioned for current phase

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
- Proceed with staged network uplift (current mixed fabric first, then full switch/NIC upgrade).
- Resume using a `supportsTensor=true` model.
- Request tensor explicitly:
  - `sharding=Tensor`
  - `instance_meta=MlxRing` first (jaccl only after suitable RDMA/all-to-all prerequisites are met)

## Network Update (June 20)
- Current links:
  - 10 Gb: maxpower and thegibson storage server (/BIGMIRROR, /NVME).
  - 5 Gb: theplague (USB path).
- In flight:
  - Complete script and unit re-targeting to new maxpower/theplague IPs.
  - Rebuild theplague exo runtime and services after OS reinstall.

## Immediate Migration Tasks (June 20)
1. Update all hardcoded node/IP references in active scripts and docs.
2. Remove debian from active control/diagnostic/startup paths (keep only in archive/historical docs).
3. Re-bootstrap theplague (exo checkout, venv/uv deps, CUDA headers, systemd unit/drop-ins).
4. Validate mounts on all active nodes:
   - `/BIGMIRROR`
   - `/NVME`
5. Re-run baseline health/start/status flow with the reduced active compute set.

## June 20 Execution Plan (Ordered)
1. Bootstrap theplague end-to-end:
   - exo checkout present
   - uv/venv dependencies installed
   - CUDA headers available to service runtime
   - exo.service created and enabled
   - `/BIGMIRROR` and `/NVME` mounted and persistent
2. Bring up active cluster (`maxpower` + `theplague`) and confirm stable topology.
3. Run model-fit discovery for the current pool before long payload testing.
4. Execute compute-distribution validation under sustained load.

## Current VRAM Budget and Model Selection Gate
- Active compute VRAM budget is now approximately 48 GB:
  - maxpower GPU A: 24 GB
  - maxpower GPU B: 12 GB
  - theplague GPU: 12 GB
- Selection rule for current phase:
  1. Candidate must place successfully with `min_nodes=3`.
  2. Candidate should report tensor-capable placement support in preview/API path.
  3. Candidate must show non-trivial SM utilization on all active ranks under load.
- Practical target class for first passes: MLX 4-bit models in the ~30B range (or smaller) that satisfy tensor-path requirements.

## Next Session Success Criteria
1. Phase A (current mixed network): document utilization baseline under 2.5/5/10 Gb mixed links.
2. Phase B (after switch/NIC delivery): re-run the same workload with upgraded links and compare scaling.
3. Placement uses a model that fits the active 48 GB pool and supports tensor path with explicit Tensor sharding.
4. Under sustained decode load, each node shows non-trivial GPU SM utilization (not only VRAM residency).
5. Per-node sampling (`nvidia-smi pmon` at 1s cadence) confirms activity across all ranks during the same request window.
6. If any node remains mostly idle while others are saturated, capture logs/state and treat run as not meeting parity target.

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
  -d '{"model_id":"<supportsTensor-model>","sharding":"Tensor","instance_meta":"MlxRing","min_nodes":3}' | jq .
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
