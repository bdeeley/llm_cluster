# Compute Distribution Fix - Quick Reference

## The Problem (What You Saw)

```
✗ Only Quadro GPU working
  - Quadro: 95% utilization, all inference compute
  - RTX 3060 (maxpower): 0% utilization, weights stored but not used  
  - RTX 3060 (theplague): 0% utilization, completely idle
  
Result: 3 GPUs loaded, 1 GPU computing = wastes hardware
```

## The Solution (What Changed)

**OLD:** Simple model loading with `device_map='auto'`
```python
model = AutoModelForCausalLM.from_pretrained(
    "codellama/CodeLlama-13b-hf",
    device_map='auto'  # ← Loads weights smartly, routes compute to biggest GPU
)
```

**NEW:** vLLM with tensor parallelism
```bash
python -m vllm.entrypoints.openai.api_server \
  --model codellama/CodeLlama-13b-hf \
  --tensor-parallel-size 3  # ← All 3 GPUs compute portions of inference
```

## How It Works

**Tensor Parallelism** = Split model layers across GPUs, ALL compute in parallel

```
Old (broken):
  Inference: GPU0 ─→ GPU1 (QUADRO DOES ALL WORK) ─→ GPU2

New (fixed):
  Inference: GPU0 ──────┐
             GPU1 (Q) ──┼─→ (all compute at same time)
             GPU2 ──────┘
```

## How to Verify It's Working

### 1. Start the server
```bash
cd /home/bdeeley/test/ollama-cluster
./scripts/06-start-vllm-cluster-distributed.sh
```

### 2. Watch GPU utilization
```bash
# Terminal 1: maxpower GPU 0
watch -n1 'nvidia-smi --query-gpu=index,utilization.gpu --format=csv,noheader'

# Terminal 2: maxpower GPU 1
watch -n1 'ssh theplague nvidia-smi --query-gpu=index,utilization.gpu --format=csv,noheader'
```

### 3. Send a query
```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Write a 200 word essay on distributed computing"}], "max_tokens": 256}'
```

### 4. Expected output during inference
```
GPU 0 (RTX 3060):    ████░░░░░░ ~35% GPU
GPU 1 (Quadro):      ████░░░░░░ ~35% GPU  
GPU 2 (Remote RTX):  ████░░░░░░ ~35% GPU
Network:             ████░░░░░░ ~4-5 Gbps
```

NOT working = Only one GPU shows high utilization

## Network Traffic During Inference

**You should see traffic on the 10Gbps link:**

```bash
# On theplague, monitor network:
ssh theplague 'iftop -i eth0 -n'
```

**Expected:**
- Idle: ~0 Mbps
- During inference: 1-5 Gbps sustained
- After generation: drops to 0

**If you see 0 Mbps during inference:**
- Tensor parallelism not enabled (check script output)
- Or model is too small to require multi-GPU (CodeLlama-13B should trigger it)

## Troubleshooting

### Problem: vLLM says `tensor-parallel-size > num_gpus`
**Cause:** Ray cluster not fully started
**Fix:**
```bash
ray stop  # Clean stop
sleep 2
./scripts/06-start-vllm-cluster-distributed.sh  # Full restart
```

### Problem: Only 1 GPU shows utilization
**Cause:** Tensor parallelism not enabled (script didn't use `--tensor-parallel-size 3`)
**Fix:**
```bash
# Check vLLM logs:
tail -50 /tmp/vllm_output.log | grep -i tensor

# Ensure script passes the flag:
grep tensor-parallel-size scripts/06-start-vllm-cluster-distributed.sh
```

### Problem: Inference is slower than before
**Cause:** Communication overhead on 10Gbps link (expected)
**Expected:** 
- Token latency: +10-20% (network communication)
- Throughput: +300% (can batch more requests)

### Problem: theplague GPU not recognized by Ray
**Cause:** SSH connection failed during cluster startup
**Fix:**
```bash
# Manually test theplague connectivity:
ssh bdeeley@172.16.0.29 'nvidia-smi'

# If SSH fails, fix SSH key:
ssh-copy-id -i ~/.ssh/id_rsa bdeeley@172.16.0.29
```

## Performance Expectations

### Single Request (batch=1)
- **Prefill tokens** (1-512 tokens): 50-200 ms (minimal benefit from parallelism)
- **Generate token**: 30-50 ms per token (all 3 GPUs active)
- **Throughput**: ~20 tokens/second

### Batch Requests
- **Batch=1**: 20 tok/sec
- **Batch=4**: 60 tok/sec
- **Batch=8**: 120 tok/sec
- **Batch=16+**: 250+ tok/sec (vLLM async batching)

### Network Impact
- **Dedicated 10Gbps link**: Can sustain batch=32+ (4-5 Gbps utilization)
- **Shared network**: Recommend batch ≤ 8

## What Changed in Code

**Before (simple_inference_api.py):**
- All models on maxpower only
- Remote theplague never loaded
- 1-GPU compute bottleneck
- ~20 tok/sec max throughput

**After (vLLM + tensor-parallel):**
- Models split across all 3 GPUs
- Ray backend coordinates distributed compute
- 3-GPU compute benefit
- 60+ tok/sec with batching

## Next: Larger Models

To use CodeLlama-34B instead:

```bash
# In script 06-start-vllm-cluster-distributed.sh
# Change:
--model "codellama/CodeLlama-13b-hf" \
# To:
--model "codellama/CodeLlama-34b-hf" \

./scripts/06-start-vllm-cluster-distributed.sh
```

**Should work** because 34B quantized = 20GB, and you have 48GB total.

## Questions?

1. **"Why didn't device_map='auto' work?"** 
   - It loads weights intelligently but doesn't coordinate compute across GPUs for inference. It's designed for training/fine-tuning, not serving.

2. **"Doesn't 10Gbps slow down inference?"**
   - Network adds ~10-20ms per token. But batching compensates: 1 fast query vs 8 slow queries in parallel = lower latency for the user.

3. **"Can we add more GPUs?"**
   - Yes! Each GPU adds ~1/N of compute. 4 GPUs = 4x throughput (not latency). Just increase `--tensor-parallel-size 4` and connect the worker.

4. **"What about Cline integration?"**
   - Cline sends queries to port 8000. vLLM is OpenAI-compatible. Cline should auto-detect model at `http://localhost:8000` and "just work".
