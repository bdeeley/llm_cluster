# Re-Architecture Deep Dive: Multi-GPU Local + Remote EXO Cluster

Date: 2026-06-21

## Problem We Were Solving
The 3-rank topology converged, placement was accepted, but rank 1 repeatedly failed with:
- `[ring] Couldn't bind socket (error: 99)`

That blocked large-model bring-up even when network/firewall issues were resolved.

## Root-Cause Findings
1. Topology and connectivity were no longer the primary blocker.
- 3 nodes and expected connections were stable after firewall cleanup.

2. Ring startup failed in rank-specific bind behavior.
- Failures were concentrated on rank 1 (maxpower master process).

3. Launch-time drift existed across runs.
- Memory role assignment and runner state were not consistently deterministic without explicit overrides.

4. Gate observability gaps delayed diagnosis.
- Runner states could be healthy (`RunnerConnected`) without being counted as pass in the gate.
- Placement detection based only on new task IDs could miss some accepted placements.

## Architecture Changes Implemented
### A. Deterministic memory-role pinning in orchestrator
`distinct-ip-rank.sh` now enforces runtime memory overrides each start:
- master: `OVERRIDE_MEMORY_MB=24000`
- remote: `OVERRIDE_MEMORY_MB=12000`
- netns local rank: `OVERRIDE_MEMORY_MB=12000`

This is applied through systemd drop-ins for managed services and explicit env for the netns worker process.

### B. Built-in ring deep-dive action
Added `diagnose-ring` action to `distinct-ip-rank.sh`.

It outputs:
- runner summary
- instance/rank/node mapping
- `hostsByNode` ordering per node
- focused `RunnerFailed` error lines

Usage:
- `./distinct-ip-rank.sh diagnose-ring`

### C. Gate robustness improvements
`cluster-success-gate.sh` was updated to:
- detect new instance by either task-delta or instance-delta
- count `RunnerConnected` as a healthy runner-progress state for Gate D

## Current Outcome
## Gate Status
- Gate B (topology): PASS
- Gate C (placement): PASS
- Gate D (runner integrity): PASS (no RunnerFailed, all runners progress)
- Gate E (bounded inference): still FAILING due no payload bytes returned within timeout window on 70B

## Operational Meaning
Cluster formation and ring connectivity are now materially improved and deterministic versus prior failures.
Remaining blocker is in end-to-end generation serving path after successful runner connection.

## Recommended Next Isolation Step
Keep current architecture and isolate only generation path:
1. Keep `distinct-ip-rank.sh` as entrypoint.
2. Run `diagnose-ring` after placement to verify connected state.
3. Add a model warm-up probe (small prompt, longer timeout) and correlate with per-runner generation logs.
4. If 70B remains non-responsive, validate Gate E with next-largest known-good tensor-capable model, then return to 70B tuning.

## Commands
- Start architecture: `./distinct-ip-rank.sh start`
- Status: `./distinct-ip-rank.sh status`
- Deep-dive: `./distinct-ip-rank.sh diagnose-ring`
- Strict gate: `./distinct-ip-rank.sh gate mlx-community/Llama-3.3-70B-Instruct-4bit 3`
- Stop: `./distinct-ip-rank.sh stop`
