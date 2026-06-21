# MLC-LLM Distributed Exploration

## Overview
MLC-LLM is the alternative MLX-based inference engine from MLC team. More mature than exo, with actual process spawning.

**Key Difference from exo**: MLC uses explicit worker processes instead of state machine actors.

---

## Architecture
```
MLC-LLM Server (maxpower:8000)
└─ Worker Pool
   ├─ Local Worker 1 (maxpower GPU 0)
   ├─ Local Worker 2 (maxpower GPU 1)
   └─ Remote Worker (theplague GPU 0)
```

## Investigation Steps

### 1. Repository Analysis
```bash
git clone https://github.com/mlc-ai/mlc-llm
cd mlc-llm
grep -r "distributed\|tensor.*parallel\|multi.*node" . --include="*.py"
grep -r "worker.*spawn\|subprocess" . --include="*.py"
```

**What to find**:
- Multi-node capabilities documentation
- Worker spawning code (should be subprocess-based, not actor)
- Tensor parallelism implementation
- Configuration for multi-GPU/multi-node

### 2. Check Current State
```bash
cd /home/bdeeley/exo
# Compare with mlc-llm design
grep -r "Runner\|actor\|subprocess" src/exo/worker/ | head -20
```

### 3. Minimal Deployment Test
```bash
# Install MLC-LLM
pip install mlc-llm

# Start single-node multi-GPU
mlc_llm serve --model meta-llama/Llama-3-8B-q4 \
  --num-workers 2 \
  --gpu-devices "0,1"

# Check processes
ps aux | grep mlc
nvidia-smi  # Verify both GPUs in use
```

### 4. Multi-Node Configuration
If MLC supports clustering:
```bash
# maxpower (master)
mlc_llm serve --model ... --role master --address 0.0.0.0:8000

# theplague (worker)
mlc_llm serve --model ... --role worker --master-addr maxpower-ip:8000
```

### 5. Test Inference
```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{...}'

# Monitor VRAM
nvidia-smi pmon -s c
```

---

## Documentation to Review

| File/URL | Purpose |
|----------|---------|
| `mlc-llm/docs/deployment.md` | Multi-node setup |
| `mlc-llm/python/mlc_llm/serve/` | Server implementation |
| `mlc-llm/python/mlc_llm/worker/` | Worker code |
| GitHub Issues: "distributed" | Community solutions |

---

## Critical Questions

1. **Multi-Node Support**: Is it production-ready?
   - Search: "multi-node distributed cluster"
   - Check GitHub issues for user reports

2. **Tensor Parallelism**: Automatic or manual shard specification?
   - How does it compare to exo's pipeline parallelism?

3. **Real Process Spawning**: Workers are subprocess-based (not actor model)?
   - Verify in `mlc_llm/worker/` source

4. **MLX Sharding**: Does MLX backend support tensor parallelism?
   - Or just pipeline sharding like exo?

5. **OpenAI Compatibility**: Full `/v1/chat/completions` support?

---

## Advantages Over exo

1. **Maturity**: MLC has been around longer (exo is newer)
2. **Process Model**: Likely uses traditional subprocess pattern (proven)
3. **Same Backend**: Still uses MLX for CUDA inference
4. **Active Development**: Stable release cycles

## Disadvantages

1. **Distributed Feature Maturity**: May be less tested than exo's libp2p approach
2. **Learning Curve**: Different deployment model than exo
3. **Community Size**: Smaller than vLLM ecosystem

---

## Decision Point

**Go if**:
- Multi-node setup is documented and stable
- VRAM actually gets consumed (real workers spawned)
- Minimal learning curve vs exo

**No-go if**:
- Multi-node is experimental/unsupported
- Still has state machine issues like exo
- Requires significant rework

---

**Estimated Investigation Time**: 2-4 hours  
**Type**: Code + Documentation review + minimal testing
