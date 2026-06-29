r# Distributed GPU Inference Architecture

## System Overview

```
┌─────────────────────────────────────────────────────┐
│                   10 Gbps Network                    │
├──────────────────────────┬──────────────────────────┤
│      maxpower            │      theplague           │
│  (Head + 2 GPUs)         │   (Worker + 1 GPU)       │
│                          │                          │
│ RTX 3060 (12GB)  ◄───┐   │  RTX 3060 (12GB)         │
│ Quadro P6000 (24GB) │   │                          │
│        ↓        ────┼───→│        ↓                 │
│   GPU Tensor 0   │ Comm  │   GPU Tensor 1          │
│   GPU Tensor 1   │       │                          │
│   GPU Tensor 2   │◄──────┤   GPU Tensor 2          │
│        ↑         │       │        ↑                 │
│    vLLM API      │       │   Ray Worker            │
│    (Port 8000)   │       │                          │
└──────────────────┴───────┴──────────────────────────┘
```

## Compute Architecture

### Without Tensor Parallelism (OLD - BROKEN)
```
Query: "What is 2+2?"
         ↓
    [Tokenize]
         ↓
  Model Weights Distribution:
    GPU0 (RTX):     20% of weights → holds 3.1 GB
    GPU1 (Quadro):  80% of weights → holds 5.9 GB
    GPU2 (Remote):  full model     → holds 6.8 GB
         ↓
    Inference Route:
    GPU0 ─→ IDLE (weights stored but not used)
    GPU1 ─→ ✓ 95% COMPUTE (all inference work)
    GPU2 ─→ IDLE (all inference goes through GPU1)
         ↓
    Output: "4"
    
PROBLEM: Only Quadro computes, network unused, RTX cards waste power
```

### With Tensor Parallelism (NEW - FIXED)
```
Query: "Write hello world"
         ↓
    [Tokenize to tokens 1-512]
         ↓
  Model Layer Distribution (Tensor Parallel):
    GPU0 (RTX):     Layers 0-40    (compute block)
    GPU1 (Quadro):  Layers 41-80   (compute block)
    GPU2 (Remote):  Layers 81-120  (compute block)
         ↓
    Token Generation Loop (each iteration):
    All 3 GPUs compute simultaneously:
    
    Step 1: tokens = [101, 102, ...]
      GPU0: compute layers 0-40 → pass hidden_states to GPU1
      GPU1: compute layers 41-80 → pass hidden_states to GPU2
      GPU2: compute layers 81-120 → pass logits back to GPU0
      (network: ~500MB all-gather + reduce patterns)
      
    Step 2: GPU0 samples next token from logits
    Step 3: repeat until end-of-sequence
         ↓
    Output: "def hello_world():\n    print('Hello, World!')"
    
BENEFIT: All 3 GPUs at 33% utilization, network 4-5 Gbps active
```

## vLLM Tensor Parallelism Setup

### Configuration
```bash
vllm.entrypoints.openai.api_server \
  --model codellama/CodeLlama-13b-hf \
  --tensor-parallel-size 3          # Split model across 3 GPUs
  --pipeline-parallel-size 1         # No pipeline stages (slower)
  --distributed-executor-backend ray # Use Ray for GPU coordination
  --gpu-memory-utilization 0.90      # Pack model tightly
  --max-model-len 4096               # Max context window
```

### Layer Distribution (CodeLlama-13B)
```
Model has 40 transformer layers + embedding + output projection

Tensor Parallel Split (each GPU gets 1/3 of layer computation):
┌─────────────────────────────────┐
│  Embedding & Position Encoding  │  (replicated on all GPUs)
├──────────────────┬──────────────┤
│ Layer 0-13       │ Attention heads: split attention computation
│ (GPU0)           │ MLP: split expert routing
├──────────────────┤
│ Layer 14-26      │ Same as GPU0 (1/3 of model computation)
│ (GPU1/Quadro)    │
├──────────────────┤
│ Layer 27-40      │ Same as GPU0/GPU1 (final 1/3)
│ (GPU2/Remote)    │
├──────────────────┴──────────────┤
│ Output Projection                │  (on GPU0, gathered logits)
└─────────────────────────────────┘

For each token:
  Input → GPU0 → GPU1 → GPU2 → GPU0 (gather) → Output
          |______|_____|______|      (all-gather ring topology)
```

## Network Communication Patterns

### All-Gather Pattern (Forward Pass)
```
All GPUs need full output from previous layer:

GPU0: hidden_state_chunk_0 ──┐
                              ├─→ GPU0: [chunk_0 | chunk_1 | chunk_2]
GPU1: hidden_state_chunk_1 ──┤    GPU1: [chunk_0 | chunk_1 | chunk_2]
                              ├─→
GPU2: hidden_state_chunk_2 ──┘    GPU2: [chunk_0 | chunk_1 | chunk_2]

Latency: log2(3) = 1.58 hops ≈ 3.2 GiB / 10 Gbps ≈ 2.5 seconds
(But pipelined with computation)
```

### Reduce-Scatter Pattern (Backward Pass during training)
```
Less relevant for inference, but mentioned for completeness.
Gradients scattered across devices for local optimization.
```

## Why 10 Gbps Network Works

**Token Generation Analysis:**
```
Model: CodeLlama-13B (fp16 weights + kv-cache)
Parallel size: 3 GPUs

Per-token communication:
  Hidden state: 4096 (hidden_dim) × 2 bytes = 8 KB
  × 3 GPUs all-gather = 24 KB
  × 2 (forward + backward) = 48 KB per step

Token generation speed: ~20-50 ms per token (batch=1)
Network bandwidth needed: 48 KB / 40 ms = 1.2 MB/s = 9.6 Mbps
Available: 10 Gbps
Utilization: 0.096%

HEADROOM: Can handle batch sizes up to ~1000 tokens/sec
```

## API Layer

### FastAPI Server
```
Port: 8000
Endpoints:
  POST /v1/chat/completions     ← OpenAI-compatible chat
  GET  /v1/models               ← List models
  GET  /health                  ← Health check
  GET  /v1/cluster/status       ← GPU memory stats
```

### Request Flow
```
cURL/Cline → FastAPI (8000)
            ↓
      vLLM Scheduler
            ↓
      Batch Requests
            ↓
      Distributed Inference
      (Ray + Tensor Parallel)
            ↓
      GPU0, GPU1, GPU2 (concurrent)
            ↓
      vLLM Response Builder
            ↓
      JSON Response → cURL/Cline
```

## Performance Characteristics

### Expected Metrics (CodeLlama-13B, Batch=1)

| Metric | Value | Notes |
|--------|-------|-------|
| Model Size | 8.0 GB | 4-bit quantization |
| Total VRAM | 24 GB | ~3GB per GPU overhead |
| Prefill (1-512 tokens) | 50-200 ms | Parallel benefit minimal |
| Decode (1 token) | 30-50 ms | All 3 GPUs active |
| Throughput | ~20 tok/sec | Single request, batch=1 |
| Max Batch Size | ~32 | Before hitting VRAM limits |
| Throughput (batch=32) | ~500 tok/sec | Full GPU utilization |
| Network Saturation | 4-5 Gbps | During token generation |
| Cross-node Latency | ~100-500 µs | Per all-gather ring |

### vs Single Quadro GPU (for comparison)
| Metric | Single GPU | 3-GPU Parallel | Improvement |
|--------|-----------|-----------------|-------------|
| Decode Speed | 30 ms | 30 ms | 0% (latency bound) |
| Throughput | 30 tok/sec | 90 tok/sec | 3x |
| Max Batch | 8 | 32 | 4x |

*Note: Single-GPU latency unchanged (limited by layer depth), throughput improves with batch size*

## Larger Model Support

### CodeLlama-34B (Next Tier)
```
Current: 13B  (8 GB in 4-bit)  → Fits 3-GPU setup ✓
Next:    34B  (20 GB in 4-bit) → Fits 3-GPU setup ✓

maxpower:  36 GB total ✓
theplague: 12 GB total ✓
Combined:  48 GB total ✓

Per GPU with 34B + tensor parallel:
  GPU0: 48 / 3 = 16 GB needed  vs 12 GB available ✗ (slightly over)
  
SOLUTION: Use pipeline parallelism (2 stages) + tensor parallel (1.5 × 1.5)
  Or: Upgrade theplague to A100 (40GB) or split 34B across 4 GPUs
```

### Memory Breakdown (CodeLlama-13B × 3 GPUs)
```
Per GPU:
  Model weights:      2.7 GB (quantized, 1/3 of full)
  KV-Cache (batch=1): 0.05 GB
  Attention buffers:  0.3 GB
  Overhead:          0.3 GB
  ─────────────────────────
  Total per GPU:     3.35 GB
  
  × 3 GPUs = 10 GB total (vs 48 GB available = 20% utilization)
```

## Troubleshooting

### All GPUs Not Computing
**Symptom:** Only Quadro has GPU utilization, others idle
**Root Cause:** vLLM using `device_map='auto'` instead of tensor parallelism
**Fix:** Ensure `--tensor-parallel-size 3` is set

### Network Latency Issues
**Symptom:** Generate speed slow, GPU utilization jumps
**Root Cause:** Undersized bandwidth, network congestion
**Fix:** Check 10Gbps link for interference, use dedicated network

### Ray Worker Not Connecting
**Symptom:** vLLM hangs during startup
**Root Cause:** SSH to theplague failed, Ray port blocked
**Fix:** 
  ```bash
  ssh theplague "ray start --address=172.16.0.28:6379 --num-gpus=1"
  ```

## Files Reference

- `scripts/06-start-vllm-cluster-distributed.sh` - Start distributed vLLM
- `scripts/07-test-3gpu-compute.sh` - Verify all GPUs computing
- `docs/GPU-COMPUTE-DISTRIBUTION.md` - Problem analysis
- `simple_inference_api.py` - Single-node alternative (slower)
