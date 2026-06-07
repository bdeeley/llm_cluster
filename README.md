# EXO LLM Cluster (Operational)

Date: June 7, 2026
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

## Cluster Snapshot (June 7)
- 4 GPUs visible in cycle (maxpower x2, theplague x1, debian x1).
- Qwen2.5-72B 4bit can distribute VRAM, but decode compute remains concentrated.
- Root constraint: model card reports supportsTensor=false (no true tensor-parallel decode for this model path).
- Decision: upgrade links to uniform 10 Gb and resume with a supportsTensor=true model.

## Next Resume Objectives
1. Bring all participating links to 10 Gb.
2. Verify software parity on all nodes (same exo commit and dependency set).
3. Place a supportsTensor=true model with explicit sharding=Tensor.
4. Validate multi-node compute with long payload + per-second nvidia-smi pmon.

## Archive
Historical reports and one-off debug scripts were moved to docs/archive and scripts/archive.
