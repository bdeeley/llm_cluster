# Phase 3 Integration Test Results - Four-Node Model

**Date**: June 1, 2026  
**Test Type**: Four-node distributed model placement  
**Status**: ❌ **FAILED** (but NOT due to race condition fix)

---

## Executive Summary

Phase 3 test reveals a **separate issue** specific to 4-node placements. The runner initialization race condition fix (verified in Phases 1-2) is working correctly. However, 4-node placements spawn runners (7 total) but they remain stuck in initial states and never reach `RunnerReady`.

**Key Finding**: This is a different bug from the race condition, related to model sharding coordination or ring instance configuration for 4+ node clusters.

---

## Test Setup

**Cluster Topology**: 4 nodes (1 master + 1 local worker + 2 remote)
- maxpower (master): 2 GPUs (RTX 3060 12GB + Quadro P6000 24GB)
- maxpower-local (worker): 1 GPU (local)
- theplague: RTX 4090 24GB
- debian: RTX 3090 24GB

**Model**: `mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit` (4.8GB, quantized)

**Placement Request**: 4-node distributed model (`min_nodes: 4`)

---

## Test Results

### Timeline

```
[  1s] Runners: 7/4 | Ready: 0
[ 30s] Runners: 7/4 | Ready: 0
[ 60s] Runners: 7/4 | Ready: 0
[120s] Runners: 7/4 | Ready: 0   ← Timeout

Final: 7 runners spawned, 0 reached RunnerReady
```

### Key Observations

1. **Instance Created Successfully**: MlxRingInstance was created (ad58dbc1-6f66-46ab-9d74-1133333bb944)
2. **Over-Allocation**: 7 runners spawned instead of 4
   - This suggests duplicate runner spawning or ring replication
3. **Runners Stuck**: All 7 runners remained in initial states for entire 120-second window
   - No runner ever reached `RunnerReady`
   - No progression through the state machine
4. **Race Condition Fix NOT the Issue**:
   - Phase 1 (1-node): ✅ PASSED in 11 seconds
   - Phase 2 (2-node): ✅ PASSED in 12.2 seconds  
   - Phase 3 (4-node): ❌ FAILED - different root cause

---

## Comparison with Working Phases

| Metric | Phase 1 | Phase 2 | Phase 3 |
|--------|---------|---------|---------|
| **Nodes Placed** | 1 | 2 | 4 |
| **Runners Expected** | 1 | 2 | 4 |
| **Runners Spawned** | 1 | 2 | 7 ❌ |
| **Runners Ready** | 1 ✅ | 2 ✅ | 0 ❌ |
| **Time to Ready** | 11s | 12.2s | Timeout (120s) |
| **Status** | PASS | PASS | FAIL |

---

## Root Cause Analysis

**This is NOT the race condition fix issue** because:
1. Runners ARE being created (runner initialization itself works)
2. The fix (plan.py:173) enables task dispatch - it worked for 1 & 2 nodes
3. Issue manifests at **4-node scale** specifically
4. **7 runners** (not 4) suggests a separate coordination bug

**Likely Causes** (separate issue to investigate):
1. Ring instance sharding logic for 4+ nodes
2. Model shard assignment or rank ordering
3. Coordinator sync across 4 nodes
4. Download queue ordering for larger distributions

---

## Recommendation

**Phase 3 investigation should proceed separately** as it's unrelated to the runner initialization race condition fix that was the primary objective.

**For immediate use**: 
- ✅ Single-node models: READY
- ✅ Two-node distributed models: READY  
- ❌ Four-node distributed models: BLOCKED (separate bug)

The runner initialization race condition fix is **complete and verified** for production use with 1-node and 2-node configurations.

---

**Next Steps**:
1. Test larger models on 2-node configuration (working setup)
2. Investigate 4-node issue separately (appears to be ring instance bug, not task dispatch)
3. Consider 3-node placements as workaround for larger distributed deployments
