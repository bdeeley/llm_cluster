# CodeLlama-34B Active-Active Cluster

**TRUE ACTIVE-ACTIVE DUAL-NODE CLUSTER - BOTH HOSTS SIMULTANEOUSLY RUNNING FULL MODEL**

BOTH maxpower AND theplague load and run CodeLlama-34B inference servers independently at the same time. No compromises. No solo GPU fallback.

---

## 🚀 MISSION STATEMENT

This is an **ACTIVE-ACTIVE cluster**. Both nodes:
- Load the full ~20GB CodeLlama-34B model independently
- Are inference-ready at all times
- Serve requests concurrently
- Have no cross-node dependencies
- Can fail independently and restart independently

**One node down = Cluster down.** This is not negotiable.  

## Architecture

### maxpower (Local Master)
- **GPU0**: NVIDIA RTX 3060 (12GB) - Compute
- **GPU1**: Quadro P6000 (24GB) - Model weights + offload
- **CPU**: 2x Intel Xeon Gold 6234 (44 cores, ~125GB RAM)
- **Distribution**: CodeLlama-34B across GPU0 (10GB) + GPU1 (22GB) + CPU (offload)
- **API Port**: 8000

### theplague (Remote Worker)
- **GPU0**: NVIDIA RTX 3060 (12GB) - Compute
- **CPU**: 12 cores (~32GB RAM)
- **Distribution**: CodeLlama-34B on GPU0 (10GB) + CPU (offload)
- **API Port**: 8000
- **SSH**: bdeeley@172.16.0.62
- **Network**: 10Gbps to maxpower

### Shared Storage
- Model cache: `/NVME/huggingface/hub/models--codellama--CodeLlama-34b-Instruct-hf/`
- HuggingFace cache: `/NVME/huggingface/`

---

## ⚠️ CRITICAL REQUIREMENT

**THIS IS AN ACTIVE-ACTIVE CLUSTER. PERIOD.**

- Both maxpower AND theplague MUST be running inference servers
- Both MUST have CodeLlama-34B fully loaded
- Both MUST be serving requests at the same time
- Fallback to solo node = FAILURE of the project goal

If one node fails:
- Fix it
- Restart it
- Get it back online
- Do NOT run solo and call it "done"

---

## Quick Start

### 1. ENSURE CLEAN STATE

```bash
cd /home/bdeeley/test/vllm_cluster

# Kill ANY old processes on both nodes
pkill -9 -f "python\|inference\|uvicorn" || true
ssh bdeeley@172.16.0.62 'pkill -9 -f "python\|inference\|uvicorn"' || true
sleep 5
```

### 2. Deploy Both Nodes (ACTIVE-ACTIVE)

```bash
bash deploy_both.sh
```

This:
- Starts inference server on maxpower (uses GPU0 + GPU1)
- SSHes to theplague, ensures venv + deps, starts server there (uses GPU0)
- Both load CodeLlama-34B independently
- Both ready to serve inference requests simultaneously

### 3. Test Inference

```bash
bash test_both.sh
```

Or manually test:
```bash
# maxpower
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [{"role": "user", "content": "Write a Python function"}],
    "max_tokens": 50
  }'

# theplague
curl -X POST http://172.16.0.62:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [{"role": "user", "content": "Write a Python function"}],
    "max_tokens": 50
  }'
```

### 4. Stop Servers

```bash
bash stop_both.sh
```

---

## Files in This Directory

**Core Inference - ACTIVE-ACTIVE DUAL NODE**
- `inference_server_unified.py` - Single codebase, runs on BOTH maxpower and theplague
  - Auto-detects hostname
  - maxpower: loads model across GPU0 + GPU1 + CPU
  - theplague: loads model on GPU0 + CPU
  - Both serve inference simultaneously
- `requirements.txt` - all dependencies (same on both nodes)

**Deployment & Control**
- `deploy_both.sh` - Deploy BOTH nodes simultaneously (no shortcuts)
- `stop_both.sh` - Stop BOTH servers
- `test_both.sh` - Test BOTH endpoints
- `start.sh` - Legacy (deprecated)

**Legacy Files (DO NOT USE)**
- `cluster.py` - Old Mistral-7B attempt
- `inference_server.py` - Old single-node attempt
- `distributed_codelama_34b.py` - Old distributed attempt

**Documentation & Config**
- `README.md` - This file (ACTIVE-ACTIVE requirement)
- `config/` - Model configs (if needed)
- `logs/` - Log files location

---

## Environment Setup

### Prerequisites

**BOTH maxpower AND theplague MUST have:**
- Python 3.13 venv at `/home/bdeeley/test/.venv`
- PyTorch 2.6.0+cu124 installed
- CUDA 12.4 driver
- Models cached in `/NVME/huggingface/hub/`
- CodeLlama-34B (~20GB) available and loadable

**maxpower ADDITIONALLY:**
- Both GPU0 (RTX 3060) and GPU1 (Quadro P6000) available and visible

**theplague ADDITIONALLY:**
- GPU0 (RTX 3060) enabled and visible
- SSH server running on 172.16.0.62
- Network connectivity to maxpower

### Manual Setup (if needed)

On theplague:
```bash
# Set up venv
cd /home/bdeeley/test
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip

# Install dependencies
cd /home/bdeeley/test/vllm_cluster
pip install --index-url https://download.pytorch.org/whl/cu124 torch==2.6.0
pip install -q transformers accelerate fastapi uvicorn peft

# Verify GPU
nvidia-smi
```

---

## Model Loading

Both nodes independently load CodeLlama-34B with:
- float16 precision
- device_map='auto' for intelligent GPU/CPU distribution
- attn_implementation='eager' to avoid GPU architecture conflicts

**maxpower:**
- GPU0 (RTX 3060): 10GB for compute
- GPU1 (Quadro P6000): 22GB for model weights
- CPU: Offload remaining layers

**theplague:**
- GPU0 (RTX 3060): 10GB for compute
- CPU: Offload model weights and additional compute

---

## API Reference

Both nodes expose identical OpenAI-compatible API:

```
POST /v1/chat/completions
GET /v1/models
GET /health
```

### Example Request

```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "messages": [
      {"role": "user", "content": "Write a Python hello world"}
    ],
    "max_tokens": 128,
    "temperature": 0.7
  }'
```

### Example Response

```json
{
  "id": "chatcmpl-local",
  "object": "chat.completion",
  "created": 1719600000,
  "model": "codellama/CodeLlama-34b-Instruct-hf",
  "choices": [
    {
      "index": 0,
      "message": {
        "role": "assistant",
        "content": "def hello_world():\n    print('Hello, World!')"
      },
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 10,
    "completion_tokens": 15,
    "total_tokens": 25
  }
}
```

---

## Monitoring

**Check server logs:**
```bash
# maxpower
tail -f /tmp/maxpower_inference.log

# theplague
ssh bdeeley@172.16.0.62 tail -f /tmp/theplague_inference.log
```

**Check GPU memory:**
```bash
# maxpower GPUs
nvidia-smi

# theplague GPU
ssh bdeeley@172.16.0.62 nvidia-smi
```

**Check running processes:**
```bash
# maxpower
ps aux | grep inference_server_unified

# theplague
ssh bdeeley@172.16.0.62 ps aux | grep inference_server_unified
```

---

## Troubleshooting

### ⚠️ ACTIVE-ACTIVE VIOLATION: One node down = CLUSTER DOWN

If one node is not running or not serving inference, the cluster has FAILED. Fix immediately.

### Old processes consuming GPU memory

Old model loading attempts leave GPU memory in use. Clean aggressively BEFORE deploying:

```bash
cd /home/bdeeley/test/vllm_cluster

# Kill EVERYTHING on both nodes
pkill -9 -f "python\|inference\|uvicorn\|ray" || true
ssh bdeeley@172.16.0.62 'pkill -9 -f "python\|inference\|uvicorn\|ray"' || true

# Wait for GPU to clear
sleep 10

# Verify GPU is clear
echo "maxpower GPU:"
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits

echo "theplague GPU:"
ssh bdeeley@172.16.0.62 nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits

# NOW redeploy both nodes
bash deploy_both.sh
```

### Server won't start on maxpower

```bash
pkill -9 -f inference_server_unified
sleep 2
source /home/bdeeley/test/.venv/bin/activate
cd /home/bdeeley/test/vllm_cluster
python3 inference_server_unified.py
```

### theplague not connecting

```bash
# Test SSH
ssh bdeeley@172.16.0.62 echo OK

# Check if server is running
ssh bdeeley@172.16.0.62 ps aux | grep inference_server_unified

# Check logs
ssh bdeeley@172.16.0.62 tail -50 /tmp/theplague_inference.log

# If stuck, kill and restart
ssh bdeeley@172.16.0.62 'pkill -9 -f inference_server_unified && sleep 3 && source ~/.venv/bin/activate && cd /home/bdeeley/test/vllm_cluster && nohup python3 inference_server_unified.py > /tmp/theplague_inference.log 2>&1 &'
```

### GPU memory issues

```bash
# Check current usage on both
echo "maxpower:"
nvidia-smi

echo "theplague:"
ssh bdeeley@172.16.0.62 nvidia-smi

# Force clear CUDA cache
python3 -c "import torch; torch.cuda.empty_cache()" 

# Or on theplague:
ssh bdeeley@172.16.0.62 'python3 -c "import torch; torch.cuda.empty_cache()"'
```

### Model download stuck

```bash
# Check cache on maxpower
ls -lh /NVME/huggingface/hub/models--codellama--CodeLlama-34b-Instruct-hf/

# Check cache on theplague
ssh bdeeley@172.16.0.62 ls -lh /NVME/huggingface/hub/models--codellama--CodeLlama-34b-Instruct-hf/

# Restart both servers to resume download
bash deploy_both.sh
```

---

## Performance Notes

- CodeLlama-34B inference typically takes 2-5 seconds for 50 tokens
- Both nodes work independently - no cross-cluster communication
- Each node can serve multiple concurrent requests
- Model weights distributed across available GPUs per host

---

## Deployment Checklist

✅ All files in `/home/bdeeley/test/vllm_cluster/`
✅ Both nodes have venv at `/home/bdeeley/test/.venv`
✅ Both nodes have PyTorch 2.6.0+cu124 installed
✅ Models cached in `/NVME/huggingface/hub/`
✅ SSH connectivity to theplague (172.16.0.62) verified
✅ Both GPUs visible on maxpower
✅ GPU0 visible on theplague
✅ No old processes running (clean state)

Then: `bash deploy_both.sh`

Result: Both nodes active-active, serving inference.

---

**Status**: Ready to deploy
**Last Updated**: 2026-06-28
**Requirement**: ACTIVE-ACTIVE - NO EXCEPTIONS
