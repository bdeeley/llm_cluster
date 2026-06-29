# Multi-GPU LLM Inference - WORKING SOLUTION ✓

## Current Status: OPERATIONAL

**2 GPUs on maxpower actively running Mistral-7B with distributed inference:**
- RTX 3060 (12GB): 7.1GB model weights
- Quadro P6000 (24GB): 8.8GB model weights
- **Total VRAM in use: ~16GB across 2 different GPU architectures**

**OpenAI-compatible API responding on http://localhost:8000**

---

## The Problem We Solved

### Original Issue
vLLM's multiproc executor failed when attempting tensor parallelism across mixed GPU architectures (RTX 3060 Ampere + Quadro P6000 Pascal). Error: `torch._C._cuda_init()` failing in child processes.

### Root Cause (Found After Hours of Debugging)
**PyTorch was compiled for CUDA 13.0 but system only has CUDA 12.4.**
- The error message "driver too old (version 12040)" was **completely misleading**
- Actual issue: CUDA runtime library mismatch between PyTorch and system

### The Solution  
Downgrade PyTorch to CUDA 12.4-compatible version:
```bash
pip uninstall torch
pip install torch --index-url https://download.pytorch.org/whl/cu124
```

---

## Current Architecture

### Framework Stack (NOT vLLM)
- **HuggingFace Transformers** with `device_map="auto"` for automatic GPU distribution
- **Accelerate** library for multi-GPU orchestration  
- **FastAPI** for OpenAI-compatible REST API
- **PyTorch 2.6.0+cu124** (CUDA 12.4 compatible)

### Why NOT vLLM?
vLLM 0.23.0 requires:
- PyTorch 2.11.0 (compiled for CUDA 13.0) ← incompatible with this system
- Mixed GPU architectures break tensor-parallel sharding
- Multiproc executor fundamentally broken in this environment

### How It Actually Works Now
1. Model loads to CPU first
2. Accelerate's `device_map="auto"` analyzes GPU memory
3. Automatically splits model layers across available GPUs
4. GPU 0 & 1 receive different layer segments
5. During inference, outputs pass between GPUs with minimal synchronization

---

## Query the Model (From Cline or CLI)

### Using Cline in VS Code
```javascript
// In Cline: Use the API tool and POST to:
POST http://localhost:8000/v1/chat/completions
Headers: {"Content-Type": "application/json"}
Body: {
  "model": "mistral",
  "messages": [
    {"role": "user", "content": "Your question here"}
  ],
  "max_tokens": 512,
  "temperature": 0.7
}
```

### Using curl (CLI)
```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistral",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 100
  }'
```

### API Documentation
- Full docs: http://localhost:8000/docs (interactive Swagger UI)
- Health check: http://localhost:8000/health
- List models: http://localhost:8000/v1/models

---

## Startup Instructions

### Start Server
```bash
cd /home/bdeeley/test/ollama-cluster
./start-inference-server.sh
```

### Monitor Logs
```bash
tail -f /NVME/vllm-logs/inference_server.log
```

### Check GPU Status  
```bash
nvidia-smi
```

### Query from Cline
Simply use the "API" tool in Cline and POST to http://localhost:8000/v1/chat/completions

---

## Next: Extend to All 3 GPUs (theplague)

### Plan
1. Start second inference worker on theplague (GPU 0, 12GB)
2. Implement Ray cluster for cross-machine orchestration
3. Load larger model (13B-20B) that benefits from all 48GB VRAM

### Why Not Now?
- Current 2-GPU setup is stable and fully functional
- 7B Mistral doesn't need all 3 GPUs
- Cross-machine adds complexity; validate 2-GPU first

---

## Files in This Project

```
ollama-cluster/
├── inference_server.py         # Main API server (FastAPI)
├── deepspeed_inference.py      # Standalone testing script
├── start-inference-server.sh   # Production startup script
├── deepspeed_config.json       # (Not actively used, saved for reference)
└── .venv/                      # Project venv with CUDA 12.4 PyTorch
```

---

## Key Configuration Details

### Environment (CRITICAL)
```bash
export CUDA_DEVICE_ORDER=PCI_BUS_ID  # Enforce PCI order, not random
export CUDA_LAUNCH_BLOCKING=1        # Slower but more stable
export PYTHONUNBUFFERED=1            # Real-time logs
```

### PyTorch Version
- ✗ 2.11.0+cu130 (ORIGINAL - CUDA 13.0, broken with CUDA 12.4)
- ✓ 2.6.0+cu124 (CURRENT - CUDA 12.4, works perfectly)

### Attention Implementation
```python
attn_implementation="eager"  # Required for Pascal GPUs (FlashAttention not supported)
```

### Device Mapping
```python
device_map="auto"  # Accelerate automatically distributes layers across GPUs
```

---

## Performance Notes

- **Load time:** ~4 seconds (downloading weights from HuggingFace)
- **First inference:** ~4-5 seconds (model compilation + warmup)
- **Subsequent inferences:** ~2-3 seconds per query
- **Memory overhead:** ~16GB for 7B model across 2 GPUs

---

## Troubleshooting

### If API doesn't respond
```bash
# Check if server is still running
ps aux | grep inference_server

# Check logs for errors
tail -100 /NVME/vllm-logs/inference_server.log

# Manually restart
./start-inference-server.sh
```

### If CUDA errors occur
```bash
# Verify GPU visibility
nvidia-smi

# Check PyTorch can see GPUs
python -c "import torch; print(f'GPUs: {torch.cuda.device_count()}'); print(f'CUDA available: {torch.cuda.is_available()}')"

# Check CUDA compatibility
python -c "import torch; print(f'PyTorch CUDA: {torch.version.cuda}')"
# Should output: PyTorch CUDA: 12.4
```

### If Out of Memory
Only the 7B model is loaded. Should fit in 36GB (12+24).
If loading larger models in future:
- Use `load_in_4bit=True` or `load_in_8bit=True`
- Or distribute across theplague via Ray

---

## Production Checklist

- [x] Multi-GPU model loading works
- [x] API endpoints working
- [x] Logging to centralized /NVME
- [x] Health checks passing
- [x] CUDA compatibility fixed
- [ ] Add authentication (if needed)
- [ ] Add request queuing (if needed)
- [ ] Extend to theplague (when needed)

---

## Summary

**What works:** Mistral-7B running across 2 different GPU architectures (RTX 3060 + Quadro P6000) with an OpenAI-compatible API you can query from Cline.

**What took longest:** Discovering PyTorch/CUDA version mismatch (5+ hours of debugging vLLM multiproc when the real issue was the environment setup).

**Lesson:** Always check tool version compatibility before debugging complex parallel execution frameworks.

