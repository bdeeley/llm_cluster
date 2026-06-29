# EXO LLM Cluster (Operational)

Date: June 21, 2026
Status: Operational and validated on distinct-IP 3-rank architecture

This repository has been consolidated.

## Canonical Docs
- CURRENT-STATUS-COMPREHENSIVE.md: live handover, known issues, current checkpoint.
- AUTOMATION-GUIDE.md: operational runbook (start, validate, place, test, stop).
- SUCCESS-ARCHITECTURE.md: deterministic architecture decision and gate model to avoid ping-pong debugging.
- REARCHITECTURE-DEEP-DIVE.md: concrete multi-GPU local+remote redesign and current gate status.
- nodes/README.md: node image/build/bootstrap workflow.
- docs/archive/README.md: index of archived reports and legacy scripts.

## Canonical Scripts (Active)
- cluster-control.sh: start/stop/status/logs for all nodes.
- distinct-ip-rank.sh: orchestrates distinct-IP second local rank (netns + macvlan) on maxpower.
- cluster-diagnose.sh: topology/service/runner diagnostics.
- exo-cluster.sh: interactive operations menu.
- deploy-all-nodes.sh: push/update common node configuration.
- setup-node.sh: node provisioning helper.
- test-single-node.sh: per-node checks.
- monitor-logs.sh: filtered live log stream across nodes.
- capture-network.sh: tcpdump helper for transport troubleshooting.
- turbo-check.sh: host CPU/turbo validation utility.
- cluster-success-gate.sh: strict pass/fail gate runner for topology, placement, runner health, and bounded inference.

## Recommended Run Path (Distinct-IP Architecture)
1. Start deterministic architecture:
  - `./distinct-ip-rank.sh start`
2. Verify status/topology:
  - `./distinct-ip-rank.sh status`
3. Run ring deep-dive snapshot (optional but recommended):
  - `./distinct-ip-rank.sh diagnose-ring`
4. Run strict gate (replace with your model):
  - `./distinct-ip-rank.sh gate mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit 3`
5. Stop cleanly:
  - `./distinct-ip-rank.sh stop`

## June 21 Checkpoint (Validated)
- End-to-end strict gate success achieved on 3-rank distinct-IP cluster.
- Verified command:
  - `./distinct-ip-rank.sh restart && ./distinct-ip-rank.sh gate mlx-community/Qwen2.5-7B-Instruct-4bit 3`
- Verified outcome:
  - Gate B PASS (topology)
  - Gate C PASS (placement)
  - Gate D PASS (runner integrity)
  - Gate E PASS (bounded inference)
- Operational fix set now in place:
  1. Trusted SSH key auth to theplague (`172.16.0.29`) from controller.
  2. Netns rank startup uses shared `XDG_DATA_HOME=/home/bdeeley/.local/share` so pre-staged models are visible.
  3. Netns rank keeps isolated `XDG_CACHE_HOME` and `XDG_CONFIG_HOME` to avoid pidfile collision with master.

## Closeout Plan (48 GB Pool)
Goal: close this phase cleanly and unblock upcoming network and node upgrades.

Phase 1: VRAM spread first (required)
1. Use pipeline-style placement to guarantee model residency across `24 + 12 + 12 GB`.
2. Pass all strict gates with the canonical command in this README.
3. Capture one stable evidence set (topology, instance/runners, bounded inference).

Phase 2: Compute distribution second (optional in this closeout)
1. Test a `supportsTensor=true` candidate with explicit `sharding=Tensor`.
2. Validate distributed compute using per-node `nvidia-smi pmon` while a sustained decode runs.
3. Promote only if all active ranks show non-trivial SM activity in the same request window.

Close criteria for this phase
1. Phase 1 is complete and repeatable (3 consecutive gate passes).
2. Cluster runbook and docs are current.
3. Any compute-parity gaps are tracked as next-phase work, not blockers for infra upgrades.

## Cluster Snapshot (June 20)
- Active compute targets: maxpower (2x GPUs) and theplague (1x RTX 3060 12 GB).
- debian is decommissioned for now.
- Qwen2.5-72B 4bit can distribute VRAM, but decode compute remains concentrated.
- Root constraint: model card reports supportsTensor=false (no true tensor-parallel decode for this model path).
- Network update: maxpower is now on 10 Gb (new IP), thegibson storage is 10 Gb, theplague is expected to run at 5 Gb (new IP, host rebuilt).

## Latest Milestone (June 21)
- **Cluster Status:** Distinct-IP 3-rank architecture validated.
- **Session Outcome:** Full strict-gate success including bounded inference.
- **What Changed:** netns startup path corrected for model visibility without pid collision, and controller-to-theplague trusted SSH was fixed.
- **Current Recommendation:** treat VRAM spread path as production-ready baseline for the 48 GB phase; do compute-parity expansion as a separate tracked phase.

## Next Resume Objectives
1. Start cluster and confirm `backend_nodes=3` before any placement attempt.
2. Fix remaining theplague Python runtime gap (`PIL`) and re-run placement smoke test.
3. Confirm all runners leave `RunnerFailed` and converge to healthy states.
4. Select an MLX candidate that fits the current 48 GB active pool (24+12+12) and passes placement checks.
5. Place a tensor-capable model with explicit `sharding=Tensor`.
6. Validate multi-node compute (SM utilization on every active GPU, not just VRAM spread) with long payload + per-second `nvidia-smi pmon`.

## Archive
Historical reports and one-off debug scripts were moved to docs/archive and scripts/archive.
