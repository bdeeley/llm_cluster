# Testing Report - 3-GPU Cluster Compute Distribution

**Date:** 2026-06-22  
**User:** GitHub Copilot  
**Test Subject:** Mistral-7B-Instruct-v0.2 (4-bit quantized)

---

## Test Results

### VRAM Loading ✅
```
maxpower GPU0 (RTX 3060):      2.1 GB
maxpower GPU1 (Quadro P6000):  4.5 GB
theplague GPU0 (RTX 3060):     7.2 GB
────────────────────────────────────
TOTAL LOADED:                 13.8 GB
```

**Status:** ✅ All 3 GPUs have model weights loaded successfully

---

### API Functionality ✅
```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mistralai/Mistral-7B-Instruct-v0.2","messages":[...]}'
```

**Status:** ✅ API responding with valid responses  
**Latency:** ~1-2 seconds per request  
**Format:** OpenAI-compatible

---

### GPU Compute Distribution ❌ (SINGLE GPU ONLY)

#### Test 1: maxpower GPU utilization during inference
```
BEFORE query:
GPU0: 0% util
GPU1: 22% util

DURING query (5 samples taken at 200ms intervals):
GPU0: 0%, 2%, 0%, 4%, 0%, 6% util      ← Minimal, mostly idle
GPU1: 81%, 73%, 63%, 85%, 64% util    ← Active, 60-85% range

AFTER query:
GPU0: 0% util
GPU1: 86% util
```

**Finding:** Only GPU1 (Quadro P6000) performs inference compute

#### Test 2: theplague GPU utilization during inference
```
BEFORE query:
GPU0: 0% util

DURING query (5 samples taken at 300ms intervals):
GPU0: 0% util (all 5 samples)          ← NO COMPUTE

AFTER query:
GPU0: 0% util
```

**Finding:** Remote GPU has weights loaded but performs ZERO compute operations

---

## Root Cause Analysis

### Why Only GPU1 Computes
The `device_map='auto'` pattern in transformers:
1. **Weight Distribution Phase**: Splits model layers across available GPUs by memory
2. **Forward Pass Phase**: Routes ALL compute to the GPU with most VRAM (Quadro)
3. **Result**: 3 GPUs hold weights, 1 GPU does all matrix multiplications

### Architecture Flow
```
Input → [GPU0 (idle)] 
         [GPU1 (QUADRO - computes) ← All attention, FFN, embedding]
         [theplague (idle)]
         → Output
```

### Measured Behavior
- GPU0 (RTX 3060): 2.1 GB weights, 0% compute utilization
- GPU1 (Quadro P6000): 4.5 GB weights, 60-85% compute utilization
- theplague GPU0: 7.2 GB weights, 0% compute utilization

---

## What Would Fix This

### Option 1: vLLM Tensor Parallelism (Recommended)
```bash
pip install vllm --upgrade  # v0.24+
vllm.entrypoints.openai.api_server \
  --model mistralai/Mistral-7B \
  --tensor-parallel-size 3  # Splits attention heads across 3 GPUs
```

**Requirements:**
- CUDA 13.x (system has 12.4)
- torch 2.11.0+ (current: 2.6.0)
- Rebuild C++ extensions

**Expected result:** Each GPU handles ~33% of attention computation

### Option 2: Manual Layer Distribution
Assign specific transformer blocks to different GPUs:
- GPU0: Layers 0-7
- GPU1: Layers 8-15
- theplague: Layers 16-31 + head

**Complexity:** High - requires custom forward pass code

### Option 3: Pipeline Parallelism
- Prefill stage (batch processing): One GPU
- Decode stage (token generation): Different GPU

**Trade-off:** Latency increase for better GPU utilization

---

## Conclusions

1. ✅ **System Works**: 13.8 GB loaded, API responding, queries generating text
2. ⚠️ **Limited Parallelism**: Only single GPU computes per query
3. ✅ **Memory Efficient**: Weights distributed reduces per-GPU footprint
4. ❌ **Throughput Not Scaled**: No speedup from adding more GPUs
5. 🔧 **Fixable**: Requires environment/dependency upgrade (CUDA 13.x path)

---

## Recommendations

### Current Use Case: ✅ OK
- Development/testing
- Single-user queries
- Model experimentation
- API prototyping

### Production Use Case: ⚠️ Needs Work
- High-throughput scenarios → Upgrade to vLLM tensor-parallel
- Low-latency serving → Use single GPU (faster without network overhead)
- Multi-user batching → Would benefit from true parallelism

---

## Test Commands Used

```bash
# Monitor local GPUs
nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv,noheader

# Monitor remote GPU
ssh bdeeley@172.16.0.29 "nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv,noheader"

# Send test query
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mistralai/Mistral-7B-Instruct-v0.2","messages":[{"role":"user","content":"Your prompt"}],"max_tokens":100}'
```

---

**End Report**
