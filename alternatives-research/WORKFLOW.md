# Exploration Workflow

## Phase 1: Rapid Research (TODAY)
- [ ] Read vLLM Ray documentation + GitHub
- [ ] Read MLC-LLM distributed docs + GitHub
- [ ] Check TensorRT-LLM Triton requirements
- [ ] Create decision matrix

## Phase 2: Quick Tests (NEXT 24 HOURS)
- [ ] vLLM single-node local multi-GPU test
- [ ] MLC-LLM repository analysis + local test
- [ ] Benchmark process spawning (verify real workers)

## Phase 3: Cluster PoC (AFTER TESTS)
- [ ] Deploy chosen system to maxpower + theplague
- [ ] Load 48GB model
- [ ] Test inference with real VRAM consumption
- [ ] Compare performance vs exo design

## Decision Matrix Template

| Factor | vLLM | MLC-LLM | TensorRT-LLM | exo (Current) |
|--------|------|---------|--------------|---------------|
| Multi-Node Support | ✅ | ? | ✅ | ❌ (broken) |
| Real Process Spawn | ✅ | ? | ✅ | ❌ (state lie) |
| OpenAI API | ✅ | ✅ | ⚠️ | ✅ |
| MLX Support | ❌ | ✅ | ❌ | ✅ |
| Setup Complexity | MEDIUM | LOW | HIGH | MEDIUM |
| Community Size | LARGE | SMALL | MEDIUM | SMALL |
| Production Ready | ✅ | ⚠️ | ✅ | ❌ |

---

## Research Commands Reference

### Check for multi-node features
```bash
# Generic search across projects
git clone <project>
cd <project>
grep -r "multi.?node\|distributed\|cluster" . --include="*.md" --include="*.py"
grep -r "worker.*spawn" . --include="*.py"
grep -r "tensor.*parallel" . --include="*.py"
```

### Test infrastructure
```bash
# Monitor GPU during inference
watch -n 0.5 'nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader'

# Verify process tree
pstree -p <parent-pid>

# Check network between nodes
ping -c 3 <remote-ip>
ssh <user>@<remote-ip> nvidia-smi
```

---

## Success Definition

By end of exploration:

1. **Know what system to deploy** (vLLM, MLC, or other)
2. **Understand multi-node story** (architecture, deployment)
3. **Identify process spawning approach** (subprocess vs actor vs other)
4. **Have deployment plan** (ready to execute)
5. **Know VRAM expectations** (how much actually gets used)

---

**Current Status**: Blocked on exo runner state machine bug  
**Timeline**: Decision by end of 2026-06-21 (24 hours)
