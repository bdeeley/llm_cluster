# EXO Cluster Current Status (Comprehensive)

Date: June 21, 2026
State: **VALIDATED** - Distinct-IP 3-rank strict gates passed, closeout baseline established.

## SESSION SUMMARY: June 21 (Closeout Validation)
**Goal:** finalize a deterministic 3-rank run and stop firefighting.
**Outcome:** Success - strict gates passed end-to-end on distinct-IP architecture.

### What Was Validated ✅
1. `./distinct-ip-rank.sh restart && ./distinct-ip-rank.sh gate mlx-community/Qwen2.5-7B-Instruct-4bit 3`
2. Gate B PASS (topology integrity)
3. Gate C PASS (placement integrity)
4. Gate D PASS (runner integrity)
5. Gate E PASS (bounded inference)

### Final Root Causes Closed ✅
1. **Trusted SSH path to theplague**
  - Controller key auth to `172.16.0.29` fixed.
2. **Netns model visibility**
  - Netns worker now reads shared model store via `XDG_DATA_HOME=/home/bdeeley/.local/share`.
3. **Netns pidfile collision**
  - Netns worker keeps isolated `XDG_CACHE_HOME=/home/bdeeley/.cache/exo-worker-netns` and `XDG_CONFIG_HOME=/home/bdeeley/.config/exo-worker-netns`.

### Closeout Decision (48 GB phase)
Use a 2-phase completion model so infrastructure upgrades can proceed:

1. **Phase 1: VRAM Spread First (DONE)**
  - Requirement: deterministic placement + inference pass on `24 + 12 + 12 GB` pool.
  - Status: achieved.

2. **Phase 2: Compute Distribution (NEXT PHASE, non-blocking)**
  - Requirement: `supportsTensor=true` model + `sharding=Tensor` + simultaneous SM activity across all ranks.
  - Status: pending and tracked separately from infra/network work.

### Immediate Next Workstream
1. Proceed with network upgrades and additional node onboarding.
2. Keep this cluster path frozen as baseline runbook.
3. Resume compute-parity experiments only after network expansion is complete.

## SESSION SUMMARY: June 20 Evening (17:30-18:15 CDT) - CLUSTER SHUTDOWN
**Goal:** Load largest model to 48GB pool, update docs, shutdown.
**Outcome:** Partial - cluster stable and placement working, but max-model validation unclear. Cluster **STOPPED cleanly**.

### What Worked This Session ✅
1. **Cluster Bring-up:** Successfully started 3-node topology (maxpower + theplague + debian decommissioned)
2. **Source Parity Fix:** Cross-node code drift (router.py) was identified and fixed via tar sync
3. **Placement Pipeline:** Instance/runner/task creation now functional (no longer no-op)
4. **Qwen2.5-7B Model:** Successfully placed with all 3 runners reaching RunnerReady state
5. **Live Inference:** Chat completions endpoint validated working correctly
6. **Clean Shutdown:** Cluster stopped successfully with all ports freed

### What Didn't Work / Blockers 🔴
1. **Topology Degradation:** Expected 3 edges, but status showed only 1 edge (partial connectivity)
2. **Orphaned Runners:** Final status showed 3 runners but 0 instances (leftover from previous test)
3. **Dependency Parity Incomplete:** theplague missing PIL, jinja2, and possibly other packages despite earlier sync attempts
4. **Max Model Validation Unclear:** Llama-3.3-70B placement attempted but runner state (RunnerReady vs RunnerFailed) never definitively confirmed
5. **Repeated Sweep Without Decision:** Model-fit sweep loop ran multiple times without clear pass/fail validation criteria
6. **No Sustained Load Test:** Got placement working but never executed a real inference workload under the largest model to confirm stability

### Root Causes Identified 🔍
| Issue | Root Cause | Fix Applied | Status |
|-------|-----------|-------------|--------|
| Topology edges=1 not 3 | Intermittent backend discovery issue | Not resolved - unclear if transient or systemic | 🟡 Pending |
| Runner failures mid-placement | Dependency gaps (PIL, jinja2 missing from theplague venv) | Partial - some packages copied but not comprehensive | 🟡 Incomplete |
| Model-fit loop without decision | No clear validation threshold defined (What counts as "success"?) | Not fixed - needs explicit criteria | 🔴 Blocker |
| No max-model confidence | Never validated that RunnerReady state persisted for 30+ seconds with large model | Not attempted | ⏳ TODO |

### Current Cluster State (at shutdown)
```
Services: ALL STOPPED ✓
Topology: Offline
APIs: Offline
Network: Ports freed, IPs quiet
Last instance count: 0
Last runner count: 3 (orphaned, no backing instances)
```

### Next Session Action Plan (CLEAR & ORDERED) 📋
**When you restart the cluster next, execute this exact sequence - NO DEVIATIONS:**

1. **Start cluster** (5 min)
   ```bash
   ./cluster-control.sh start
   ./cluster-control.sh status
   ```
   ✅ Success criteria: All 3 nodes ACTIVE, topology 3 nodes visible, edge count = 3

2. **Fix theplague dependency parity ONCE** (10 min) ⚠️ THIS IS CRITICAL
   - Current gaps: PIL (Pillow), jinja2, possibly others
   - Option A (fast): Mount maxpower:/NVME/.../venv on theplague via NFS, test if works
   - Option B (clean): Re-run full `pip install` on theplague with exact same requirements.txt as maxpower
   - Document which packages are actually missing: `cd /path/to/theplague && python -c "import mlx, PIL, jinja2, pydantic; print('OK')"`

3. **Pick ONE model and validate definitively** (15 min) - DO NOT LOOP
   - Selected model: **Llama-3.3-70B-Instruct-4bit** (~37GB, targets 48GB pool)
   - Place it: `curl -X POST http://localhost:52415/place_instance -d '{"model_id":"meta-llama/Llama-3.3-70B-Instruct-4bit","min_nodes":3}'`
   - Wait 60 seconds
   - Check result: `curl -s http://localhost:52415/state | jq '.runners'`
   - **PASS criteria:** All 3 runners show `"RunnerReady"` (not RunnerFailed, not RunnerLoading, not RunnerConnecting)
   - **FAIL criteria:** Any runner shows RunnerFailed, or runners don't reach RunnerReady after 60 seconds
   - Document the result in this file before proceeding

4. **If PASS on large model:** Run sustained load test (10 min)
   - Send 5 chat completions with 500-token generation
   - Monitor: `nvidia-smi pmon` on each node (1s cadence) - capture if all GPUs show SM% > 10%
   - Test successful if all 3 nodes show activity

5. **If FAIL:** Diagnosis (15 min)
   - Check master logs: `tail -100 /BIGMIRROR/exo-cluster.log | grep -i "runner\|error\|failed"`
   - Check runner stderr on theplague: `journalctl -u exo.service -n 50`
   - Root cause is either: (a) dependency still missing, (b) topology disconnected, (c) model incompatibility
   - Fix identified issue and go back to step 3

6. **Document result & shutdown** (5 min)
   - Add new "SESSION: [date]" section to this file with outcome
   - `./cluster-control.sh stop`
   - Commit to git with message "Session [date]: [outcome]"

### Current VRAM Budget & Model Selection
- **Active:** 48 GB total (maxpower 24GB + 12GB, theplague 12GB)
- **Target:** Largest model that reaches RunnerReady on all 3 nodes
- **Candidates (largest first):**
  1. Llama-3.3-70B-Instruct-4bit (~37 GB) ← PRIMARY TARGET
  2. Qwen2.5-72B-Instruct-4bit (~40 GB) - but reports `supportsTensor=false`
  3. Qwen2.5-7B-Instruct-4bit (~2 GB) ← KNOWN TO WORK
  4. Mistral-Nemo-12B (~7 GB)

## Latest Operational Update (June 20, 16:00 CDT)
- Revalidated cluster bring-up on active nodes (`maxpower` + `theplague`) and reached stable `topology_nodes=3`, `backend_nodes=3`.
- Root cause of prior placement no-op was confirmed and fixed:
  - Cross-node source drift in `src/exo/routing/router.py` (theplague differed from maxpower).
  - This caused `LocalForwarderEvent`/`NodeGatheredInfo` validation failures on theplague and prevented backend participation.
  - Source parity was restored by syncing `src/` from maxpower to theplague.
- After source parity, placement started materializing correctly:
  - `place_instance` now creates instances, runners, and tasks (no longer ACK-only/no-op).
- Remaining blocker is dependency parity on theplague runner environment:
  - Initially failed with `ModuleNotFoundError: No module named 'mlx'`.
  - Then failed with `ImportError: libcudnn.so.9`.
  - After copying MLX + NVIDIA runtime artifacts from maxpower, current failure progressed to `ModuleNotFoundError: No module named 'PIL'`.
- Conclusion at stop point:
  - Cluster coordination and placement pipeline are now functioning.
  - Final runner stability on theplague still requires finishing Python package/runtime parity.

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

### Task Status Delta
- Completed:
  - Script/doc retargeting to current IPs and active nodes.
  - `cluster-control.sh` hardening and realistic status checks.
  - theplague backend visibility restored (3 backend nodes visible).
  - Placement path restored from no-op to active instance/runner/task creation.
- In progress:
  - theplague runtime dependency parity for runner process (`PIL` currently missing).
- Next:
  - Install missing Python imaging dependency on theplague and re-run 3-node placement smoke.
  - Validate all runners converge to non-failed states before sustained utilization testing.

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

2. Validate topology/health and backend parity:
```bash
./cluster-diagnose.sh all
curl -s http://localhost:52415/state | jq '{nodes:(.nodeIdentities|length), conns:(.topology.connections|keys|length), backend_nodes:(.nodeBackends|keys|length), instances:(.instances|length), runners:(.runners|length)}'
```

3. If a runner fails, inspect direct failure reason first:
```bash
curl -s http://localhost:52415/state | jq '.runners | to_entries[] | select(.value.RunnerFailed) | {runner:.key, error:.value.RunnerFailed.errorMessage}'
```

4. Place tensor-capable model:
```bash
curl -s -X POST http://localhost:52415/place_instance \
  -H 'Content-Type: application/json' \
  -d '{"model_id":"<supportsTensor-model>","sharding":"Tensor","instance_meta":"MlxRing","min_nodes":3}' | jq .
```

5. Validate compute distribution under load:
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
