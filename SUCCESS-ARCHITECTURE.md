# Success Architecture (No Ping-Pong Model)

Date: 2026-06-21

## Objective
Make cluster operation deterministic for the 48 GB target and stop iterative guesswork.

## Why Prior Attempts Bounced
- Same-IP dual-daemon ring setup is fragile for MLX ring connect in current EXO runtime.
- Placement ACK is not a success signal by itself.
- Node contamination and stale listeners created false topology state.
- No strict gate criteria were enforced between start, placement, and inference.

## Recommended Architecture (Primary)
Use one logical rank per routable IP endpoint.

### Topology
- rank0: maxpower-r0, IP `172.16.0.28`, GPU `P6000 24GB`
- rank1: maxpower-r1, distinct network namespace + distinct IP (example `172.16.0.38`), GPU `RTX3060 12GB`
- rank2: theplague, IP `172.16.0.29`, GPU `RTX3060 12GB`

Total pool: 24 + 12 + 12 = 48 GB.

### Key Rule
Do not run two participating ranks on the same IP address. If two ranks share a host, they still must have distinct routable IPs.

## Alternative Architecture (Immediate Fallback)
If distinct-IP rank1 is not ready yet:
- Run stable 2-rank mode only (`maxpower` + `theplague`) for ongoing ops.
- Use smaller validated models for production reliability.
- Keep 48 GB objective blocked until distinct-IP rank1 is enabled.

This avoids further ring-level churn while still delivering usable throughput.

## Operational Gates (Must Pass In Order)
1. Gate A: Clean start
- No stale listeners on `52415/52416/5678/5680/5679`.
- Only expected EXO processes running.

2. Gate B: Topology integrity
- Exact expected node count present.
- No unknown nodes.
- Connections exist for each non-master node.

3. Gate C: Placement integrity
- `instances == 1` within timeout.
- Runner set size matches expected ranks.

4. Gate D: Runner integrity
- No `RunnerFailed` for the observation window.
- All runners progress to `RunnerIdle` or `RunnerReady` (model dependent).

5. Gate E: Inference integrity
- Bounded `/v1/chat/completions` returns valid payload.

Any failed gate is a hard stop. Fix that gate only, then re-run from Gate A.

## Anti Ping-Pong Rules
- Never continue after a failed gate.
- Never infer success from `Command received`.
- Never place before topology gate passes.
- Never patch multiple dimensions at once (network + placement + model).

## Execution Standard
Use `cluster-success-gate.sh` to enforce the gates and produce a single pass/fail result per run.

## Definition of Success
- Topology: expected nodes only.
- Placement: single target instance appears.
- Runners: no failures in window.
- Inference: bounded request returns content.
- Repeatability: same result across 3 consecutive runs.

## Closeout Posture (June 21)
To end firefighting and unblock pending infra work, split acceptance criteria:

1. Phase 1 (required): VRAM spread + bounded inference
- Distinct-IP 3-rank run is accepted when gates B/C/D/E pass on the 48 GB pool.
- This phase is now validated and should be treated as the stable baseline.

2. Phase 2 (deferred): distributed decode compute parity
- Requires `supportsTensor=true` model and explicit tensor sharding path validation.
- Requires concurrent SM activity evidence on all active GPUs under sustained decode.
- This is a follow-on optimization phase, not a blocker for network/node upgrades.
