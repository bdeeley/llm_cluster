# EXO LLM Cluster (Operational)

Date: June 20, 2026
Status: Paused intentionally (all EXO services stopped)

This repository has been consolidated.

## Canonical Docs
- CURRENT-STATUS-COMPREHENSIVE.md: live handover, known issues, current checkpoint.
- AUTOMATION-GUIDE.md: operational runbook (start, validate, place, test, stop).
- nodes/README.md: node image/build/bootstrap workflow.
- docs/archive/README.md: index of archived reports and legacy scripts.

## Canonical Scripts (Active)
- cluster-control.sh: start/stop/status/logs for all nodes.
- cluster-diagnose.sh: topology/service/runner diagnostics.
- exo-cluster.sh: interactive operations menu.
- deploy-all-nodes.sh: push/update common node configuration.
- setup-node.sh: node provisioning helper.
- test-single-node.sh: per-node checks.
- monitor-logs.sh: filtered live log stream across nodes.
- capture-network.sh: tcpdump helper for transport troubleshooting.
- turbo-check.sh: host CPU/turbo validation utility.

## Cluster Snapshot (June 20)
- Active compute targets: maxpower (2x GPUs) and theplague (1x RTX 3060 12 GB).
- debian is decommissioned for now.
- Qwen2.5-72B 4bit can distribute VRAM, but decode compute remains concentrated.
- Root constraint: model card reports supportsTensor=false (no true tensor-parallel decode for this model path).
- Network update: maxpower is now on 10 Gb (new IP), thegibson storage is 10 Gb, theplague is expected to run at 5 Gb (new IP, host rebuilt).

## Next Resume Objectives
1. Re-target scripts/services to the new maxpower/theplague IPs and active node set.
2. Verify software parity on all nodes (same exo commit and dependency set).
3. Rebuild theplague runtime/services after OS format and confirm mount parity.
4. Select an MLX candidate that fits the current 48 GB active pool (24+12+12) and passes placement checks.
5. Place a tensor-capable model with explicit sharding=Tensor.
6. Validate multi-node compute (SM utilization on every active GPU, not just VRAM spread) with long payload + per-second nvidia-smi pmon.

## Archive
Historical reports and one-off debug scripts were moved to docs/archive and scripts/archive.
