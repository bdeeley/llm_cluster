# GPU Compute Distribution Problem & Solution

## Current Status (Before Fix)

**Hardware:**
- maxpower: GPU0 (RTX 3060, 12GB) + GPU1 (Quadro P6000, 24GB)
- theplague: GPU0 (RTX 3060, 12GB)
- Network: 10Gbps between nodes
- Model: CodeLlama-13B (4-bit quantized, ~8GB total)

**Problem Observed:**
```
maxpower GPU0 (RTX):     3.1 GB VRAM ✓  |  0% COMPUTE ✗
maxpower GPU1 (Quadro):  5.9 GB VRAM ✓  |  ~95% COMPUTE (ALL LOAD)
theplague GPU0 (RTX):    6.8 GB VRAM ✓  |  0% COMPUTE ✗
────────────────────────────────────────
NETWORK: Idle (no cross-node inference)
```

**Root Cause:**
- `device_map='auto'` loads model shards intelligently (weight distribution)
- BUT routes ALL inference compute to the GPU with most free memory (Quadro)
- RTX cards become "dumb storage" devices
- Remote theplague GPU completely idle - no tensor parallelism

## Solution: vLLM Tensor Parallelism

vLLM's `--tensor-parallel-size` flag forces true distributed computation:

```bash
python -m vllm.entrypoints.openai.api_server \
  --model codellama/CodeLlama-13b-hf \
  --tensor-parallel-size 3 \           # All 3 GPUs participate
  --pipeline-parallel-size 1 \          # Single pipeline (avoid network bottleneck)
  --gpu-memory-utilization 0.90 \       # Pack layers tightly
  --port 8000 \
  --max-model-len 4096 \                # Context window
  --disable-log-requests
```

**How Tensor Parallelism Works:**
1. Model layers split ACROSS GPUs (not replicated)
2. Each GPU computes assigned layers for EVERY token
3. GPUs communicate via 10Gbps network link
4. ALL GPUs busy during inference ✓

**Expected After Fix:**
```
maxpower GPU0 (RTX):     ~9 GB VRAM  |  ~33% COMPUTE (1/3 of inference)
maxpower GPU1 (Quadro):  ~15 GB VRAM |  ~33% COMPUTE (1/3 of inference)
theplague GPU0 (RTX):    ~8 GB VRAM  |  ~33% COMPUTE (1/3 of inference)
────────────────────────────────────
NETWORK: ~4 Gbps active (all-gather, reduce-scatter patterns)
```

## Why Not Pipeline Parallelism?

Pipeline parallelism (`--pipeline-parallel-size 3`) would be worse:
- GPU0 computes layers 0-40
- GPU1 computes layers 41-80
- GPU2 computes layers 121-120
- Result: GPUs work sequentially → SLOWER than single-GPU inference
- Network becomes serialization bottleneck (must wait for previous GPU)

## Why Not Ray Actors?

Ray distributed actors had issues:
- Remote actor initialization hanging
- HF cache path not propagating across SSH workers  
- Manual synchronization required (ray.get())
- Less mature async batching than vLLM

## Larger Model Support

Current: CodeLlama-13B (8GB in 4-bit) - uses ~23GB total VRAM
Next: CodeLlama-34B (20GB in 4-bit) - needs ~35GB total VRAM

**Available:**
- maxpower: 36GB total
- theplague: 12GB total
- Combined: 48GB ✓

CodeLlama-34B fits! But need to:
1. Fix compute distribution first (tensor parallelism)
2. Add theplague worker to vLLM cluster
3. Verify 10Gbps network handles 34B inference load

## Network Requirements

**Token generation throughput:**
- 1 token per GPU per inference step
- 3 GPUs × 3 attention heads each = 9 attention computations
- Each needs weight shard exchange: ~500 MB per token
- At 10 tokens/sec target: 5 Gbps sustained
- Our 10Gbps link has headroom ✓

**Bottleneck:** Token latency (all-gather sync point)
- Theoretical minimum: 500MB / 10Gbps = 400ms per token
- In practice: ~50-100ms with pipelining in vLLM

## Current Async Batching

vLLM automatically batches requests:
- Multiple inferences can queue
- Scheduler fills GPU memory efficiently  
- Overlaps network communication with compute
- No manual batching needed

## Testing Plan

1. Start vLLM with tensor-parallel-size=3 on maxpower+theplague
2. Monitor GPU utilization (all should be ~33% during inference)
3. Test latency: `curl /v1/chat/completions`
4. Measure throughput: concurrent requests
5. Verify network saturation: `iftop` during load
