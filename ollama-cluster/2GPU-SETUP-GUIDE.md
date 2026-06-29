# 2-GPU RTX 3060 Distributed Inference - Setup Guide

## Problem Statement

**Previous Issue**: P6000 requires CUDA 13.x, but system is CUDA 12.4
- Created version conflicts
- Mixed architecture (Ampere + Pascal) complicated tensor parallelism
- Compute wasn't distributed (only Quadro computing)

**New Approach**: Use only RTX 3060s (both Ampere architecture, CUDA 12.4 compatible)
- Same CUDA generation → no compatibility issues
- True tensor parallelism across distributed GPUs
- Both VRAM and compute spread equally

---

## Hardware Setup

```
┌─────────────────────────────────────────────────────────────────┐
│ maxpower (Head Node)                                            │
│  GPU0: RTX 3060 (12 GB) ← Only this GPU                        │
│  GPU1: Quadro P6000 (24 GB) ← DISABLED for this setup          │
│  CPU: 2x Xeon Gold 6234 (44 cores)                             │
└─────────────────────────────────────────────────────────────────┘
         │ 10Gbps Network │
         ↓                 ↓
┌─────────────────────────────────────────────────────────────────┐
│ theplague (Worker Node)                                         │
│  GPU0: RTX 3060 (12 GB) ← Only this GPU                        │
│  CPU: 12 cores                                                  │
└─────────────────────────────────────────────────────────────────┘

Total VRAM: 24 GB
Both GPUs: Ampere architecture, CUDA 12.4 compatible
```

---

## Model Choice: CodeLlama-34B-Instruct (4-bit)

Why CodeLlama-34B specifically:
- **Size**: ~20GB when quantized to 4-bit
- **Fits**: Perfectly in 24GB total VRAM with headroom
- **Attention heads**: 80 (divisible by 2) → works with tensor-parallel-size=2
- **Quality**: Better instruction-following than 13B version

Alternative models (if needed):
- **Mistral-7B** (32 heads): Smaller, faster, 4-bit = ~7GB
- **Llama-2-13B** (40 heads): Larger, 4-bit = ~13GB
- **Llama-3-8B** (32 heads): Newer, 4-bit = ~8GB

---

## How Tensor Parallelism Works

### Before (Single GPU Compute):
```
Model Split: GPU0=Layers0-40 | GPU1=Layers41-80
Query: "What is 2+2?"
├─ Token 1: GPU0 (idle) → GPU1 (QUADRO 100%) → GPU0 (idle) → GPU1 (QUADRO)
├─ Token 2: GPU0 (idle) → GPU1 (QUADRO 100%) → GPU0 (idle) → GPU1 (QUADRO)
└─ Result: Single GPU bottleneck, 2 other GPUs waste VRAM storage

Performance: ~20 tok/sec
```

### After (Distributed Compute):
```
Model Split: GPU0=Layers0-40 | GPU1=Layers41-80
Query: "What is 2+2?"
├─ Token 1: GPU0 (50%) ↔ GPU1 (50%) [all-gather sync, 10Gbps]
├─ Token 2: GPU0 (50%) ↔ GPU1 (50%) [all-gather sync, 10Gbps]
└─ Result: Both GPUs compute in parallel

Performance: ~35-50 tok/sec (2x improvement)
Network: 2-5 Gbps during inference
```

---

## Step-by-Step Setup

### 1. Verify Prerequisites

```bash
# Check local CUDA 12.4
nvidia-smi | grep "CUDA Version"  # Should show 12.4

# Check venv
source /home/bdeeley/test/.venv/bin/activate
python -c "import torch; print(torch.__version__)"  # Should have +cu124

# Check vLLM
python -c "import vllm; print(vllm.__version__)"

# Check SSH to theplague
ssh bdeeley@172.16.0.29 "nvidia-smi | head -3"
```

### 2. Run the Setup Script

```bash
cd /home/bdeeley/test/ollama-cluster
./scripts/09-start-2gpu-distributed-3060.sh
```

This will:
1. Clean up any old Ray processes
2. Start Ray head on maxpower (GPU0 only)
3. Connect Ray worker on theplague (GPU0 only)
4. Verify cluster has 2 total GPUs
5. Start vLLM with tensor-parallel-size=2
6. Download model (if not cached) - first run takes 2-3 minutes
7. Start listening on `http://localhost:8000`

**Expected output:**
```
Step 1️⃣  : Checking prerequisites...
Step 2️⃣  : Cleaning Ray state...
Step 3️⃣  : Starting Ray head on maxpower (1 GPU)...
Step 4️⃣  : Connecting Ray worker on theplague (1 GPU)...
Step 5️⃣  : Verifying Ray cluster (2 GPUs total)...
  Ray cluster: 2 nodes
    Node 1: 1 GPU(s), 16 CPUs
    Node 2: 1 GPU(s), 12 CPUs
  ✓ Cluster ready: 2 total GPUs
Step 6️⃣  : Checking model size vs VRAM...
Step 7️⃣  : Configuring environment...
Step 8️⃣  : Ensuring model is downloaded...
Step 9️⃣  : Starting vLLM server...
  Model:              codellama/CodeLlama-34b-Instruct-hf
  Tensor parallel:    2
  API endpoint:       http://localhost:8000
  Expected ready in:  60-120 seconds
```

### 3. Verify Both VRAM and Compute Are Distributed

In a separate terminal:
```bash
./scripts/10-verify-2gpu-compute-spread.sh
```

This will:
- Check VRAM on both GPUs (should each have ~10-12GB of model)
- Send an inference query
- Monitor GPU utilization during inference (both should spike)
- Measure latency and throughput

**Success criteria:**
- ✅ Maxpower GPU0: 10-12 GB VRAM in use
- ✅ Theplague GPU0: 10-12 GB VRAM in use
- ✅ During inference: BOTH GPUs show 40-60% compute utilization
- ✅ Latency: < 10 seconds per query
- ✅ API responses working correctly

---

## Usage: Send Queries

### Option 1: Simple curl
```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "codellama/CodeLlama-34b-Instruct-hf",
    "messages": [{"role": "user", "content": "What is tensor parallelism?"}],
    "max_tokens": 256,
    "temperature": 0.7
  }' | jq '.choices[0].message.content'
```

### Option 2: Python Script
```python
import openai
import os

# Configure client
openai.api_base = "http://localhost:8000/v1"
openai.api_key = "not-needed-for-local"

# Send request
response = openai.ChatCompletion.create(
    model="codellama/CodeLlama-34b-Instruct-hf",
    messages=[
        {"role": "user", "content": "Write a hello world in Rust"}
    ],
    temperature=0.7,
    max_tokens=256
)

print(response.choices[0].message.content)
```

### Option 3: Monitor GPUs While Querying

**Terminal 1:** Start the server
```bash
./scripts/09-start-2gpu-distributed-3060.sh
```

**Terminal 2:** Watch local GPU
```bash
watch -n0.5 'nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits'
```

**Terminal 3:** Watch remote GPU
```bash
ssh theplague 'watch -n0.5 "nvidia-smi --query-gpu=index,utilization.gpu,memory.used,memory.total --format=csv,noheader,nounits"'
```

**Terminal 4:** Send queries
```bash
# Send query and watch all 3 terminals spike
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Tell me about distributed systems"}],"max_tokens":512}'
```

---

## Troubleshooting

### Problem: "Ray Cluster: 1 GPU found (expected 2)"

**Check 1: SSH works**
```bash
ssh bdeeley@172.16.0.29 "nvidia-smi | head -3"
# If this fails, fix SSH keys:
ssh-copy-id -i ~/.ssh/id_rsa bdeeley@172.16.0.29
```

**Check 2: Ray worker actually started**
```bash
ssh bdeeley@172.16.0.29 "ps aux | grep ray"
# Should show ray processes
```

**Check 3: Try manual Ray connection**
```bash
ray status  # Should show 2 nodes
```

### Problem: "Model download hanging"

**Check connectivity:**
```bash
curl -I https://huggingface.co/codellama/CodeLlama-34b-Instruct-hf
```

**Use cached model:**
```bash
# If model already downloaded elsewhere, point to it:
export HF_HUB_CACHE=/NVME/huggingface/hub
./scripts/09-start-2gpu-distributed-3060.sh
```

### Problem: "Only one GPU showing compute during inference"

**Check CUDA_VISIBLE_DEVICES:**
```bash
# Script should auto-set to GPU0 only on maxpower
echo $CUDA_VISIBLE_DEVICES  # Should be "0"

# Verify vLLM saw it:
grep "CUDA_VISIBLE_DEVICES" /tmp/vllm_2gpu.log
```

**Check tensor-parallel-size:**
```bash
grep "tensor.parallel" /tmp/vllm_2gpu.log
# Should show: "tensor_parallel_size=2"
```

### Problem: "Network latency too high"

**Check 10Gbps link is active:**
```bash
# Run on theplague during inference
iftop -i eth0 -n

# Should see sustained 1-5 Gbps traffic during requests
```

**Check network connectivity:**
```bash
ping -c 4 172.16.0.28  # maxpower from theplague
# Should see < 1ms latency
```

---

## Performance Expectations

### First Query (Cold Start)
- Time: 10-30 seconds
- Why: Compiling GPU kernels, warming up worker processes
- GPU utilization: Ramping up gradually

### Subsequent Queries (Warm)
- Time: 2-8 seconds per 256 tokens
- GPU utilization: Both GPUs 40-60%
- Throughput: 30-50 tokens/second
- Network: 2-5 Gbps sustained

### Batch Processing
- Batch size 1: 1-2 queries/sec
- Batch size 4: 3-5 queries/sec (vLLM async batching)
- Network: Stays at 2-5 Gbps (same link utilization)

---

## Why This Setup is Correct

✅ **VRAM Distributed**: Model layers split across both 12GB GPUs  
✅ **Compute Distributed**: Both GPUs perform inference operations in parallel  
✅ **No CUDA Conflicts**: Both RTX 3060s use CUDA 12.4  
✅ **Network Efficient**: 10Gbps link handles all-gather communication easily  
✅ **Scalable**: Foundation for adding 3rd/4th GPU later  

---

## Next Optimization Steps (Optional)

### 1. Adjust GPU Memory Utilization
If you see OOM errors, reduce from 0.90 to 0.85:
```bash
# Edit script line:
# --gpu-memory-utilization 0.85
```

### 2. Use Larger Model
If you want to use CodeLlama-34B-Full (not quantized) or Llama2-70B:
- Requires 4+ GPUs
- Edit script to add more GPUs and adjust tensor-parallel-size

### 3. Add 3rd GPU (if needed later)
- Add Quadro P6000 but use separate CUDA devices
- Requires CUDA 13.x upgrade OR using Quadro for different purpose
- Current setup stays stable with just 2x 3060s

---

## Files Reference

- **Setup script**: `scripts/09-start-2gpu-distributed-3060.sh`
- **Verification script**: `scripts/10-verify-2gpu-compute-spread.sh`
- **vLLM logs**: `/tmp/vllm_2gpu.log`
- **Ray logs**: `/tmp/ray_*.log`
- **Model cache**: `/NVME/huggingface/`

---

## Quick Reference Commands

```bash
# Start server
cd /home/bdeeley/test/ollama-cluster
./scripts/09-start-2gpu-distributed-3060.sh

# In another terminal: verify setup
./scripts/10-verify-2gpu-compute-spread.sh

# Quick test (single query)
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello"}],"max_tokens":100}'

# Monitor GPUs
watch -n0.5 'nvidia-smi'
ssh theplague 'watch -n0.5 nvidia-smi'

# Stop server
# Press Ctrl+C in the terminal running the script
# Clean up:
ray stop
pkill -f vllm
```

---

**Status**: Ready to execute  
**Date**: 2026-06-28  
**Next Action**: Run `./scripts/09-start-2gpu-distributed-3060.sh`
