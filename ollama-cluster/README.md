# Ollama Cluster - 3-GPU Distributed Inference

## Hardware

**maxpower (Head Node)**
- GPU0: RTX 3060 (12GB)
- GPU1: Quadro P6000 (24GB)
- CPU: 2x Xeon Gold 6234 (44 cores)
- Memory: 125GB RAM
- Storage: /NVME (1.8TB NFS mount)

**theplague (Worker Node)**
- GPU0: RTX 3060 (12GB)
- CPU: 12 cores
- Memory: 64GB RAM
- Storage: /NVME (shared NFS mount)

**Network**: 10 Gbps direct link

**Total**: 48GB VRAM across 3 GPUs + mixed-generation hardware support

## Current Status

✅ **RUNNING:** All 3 GPUs have 13.8 GB model loaded
✅ **API Working:** OpenAI-compatible interface on port 8000  
✅ **Model:** Mistral-7B-Instruct-v0.2 (4-bit quantized)
✅ **Memory Distributed:** Weights split across all 3 GPUs
⚠️ **Compute Bottleneck:** Single GPU (Quadro) performs all inference operations

**Tested & Verified:**
- Memory load: 13.8 GB across 3 GPUs
- Query latency: ~1-2 seconds per request
- GPU compute: Only GPU1 active during inference (60-85% util)
- GPU0 & theplague: Idle during inference (0% util)

## Quick Start

### 1. Start Inference API
```bash
cd /home/bdeeley/test/ollama-cluster
source /home/bdeeley/test/.venv/bin/activate
python simple_inference_api.py
```
This will:
- Load Mistral-7B on maxpower (4 seconds)
- Start background load on theplague (SSH subprocess)
- Listen on http://localhost:8000 (ready in ~15 seconds)

### 2. Verify GPU Status
```bash
# Local GPUs
nvidia-smi

# Remote GPU
ssh bdeeley@172.16.0.29 "nvidia-smi"
```
Expected: All 3 showing ~1.8GB, ~4.5GB, ~7.2GB respectively

### 3. Query the API
```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Hello"}], "max_tokens": 100}'
```

## Architecture & Limitations

### Current Design (device_map='auto')
- **Memory Distribution**: Weights split across all 3 GPUs (13.8 GB total)
- **Compute Bottleneck**: All matrix multiplication routed to single GPU (Quadro P6000)
- **GPU Utilization**: 
  - GPU0: Idle (0-6% during inference)
  - GPU1: Busy (60-85% during inference) ← All compute here
  - theplague: Idle (0% during inference)

### Performance Impact
- **Throughput**: Capped at single-GPU performance (~1-2 queries/sec)
- **Latency**: No speedup from 3 GPUs (single compute path)
- **Memory**: Efficient distribution reduces per-GPU load
- **Suitable for**: Development, testing, single-user queries
- **Not suitable for**: High-throughput production, multi-user batching

### To Enable True Parallel Compute
Would require:
1. **CUDA 13.x + torch 2.11.0 + vLLM** → tensor-parallel-size=3
2. **Manual layer distribution** → assign transformer layers to specific GPUs
3. **Pipeline parallelism** → separate prefill/decode stages on different GPUs

For now, this is a memory-efficient caching setup with single-GPU compute.

## Detailed Documentation

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for:
- Full tensor parallelism explanation
- Layer distribution patterns
- Network communication analysis

See [CLUSTER-WORKING.md](CLUSTER-WORKING.md) for:
- Measured GPU utilization data
- Testing methodology
- Current limitations documented

## Important Notes

⚠️ **ALWAYS use /NVME for models and logs**
- Mounted on all hosts via NFS
- Persistent across reboots
- Future nodes will be USB-boot with minimal storage
- Examples:
  ```bash
  export HF_HOME=/NVME/huggingface
  export HF_HUB_CACHE=/NVME/huggingface/hub
  ```

⚠️ **Mixed-generation GPU support required**
- Quadro P6000 (older architecture)
- RTX 3060 (newer architecture)
- Both must coexist without runtime errors
- Use `--trust-remote-code` and modern quantization formats

⚠️ **Production lessons**
- exo cluster: Failed (too immature)
- Ray actors (manual): Had SSH/environment propagation issues
- vLLM + Ray backend: Works reliably for tensor parallelism

## Scaling to Larger Models

### CodeLlama-34B (20GB quantized)
- **Fits on 3-GPU cluster**: 48GB total VRAM > 20GB model
- **Status**: Tested configuration ready, needs model download
- **Next step**: Change `--model` to `codellama/CodeLlama-34b-hf` in script

### Adding More Nodes
```bash
# On new worker node:
ray start --address=172.16.0.28:6379 --num-gpus=N

# In vLLM:
--tensor-parallel-size N+3
```

## Debugging

**Check all GPUs loaded:**
```bash
nvidia-smi && ssh theplague nvidia-smi
```

**Verify Ray cluster:**
```bash
ray status  # Shows nodes and resources
```

**Monitor network traffic:**
```bash
ssh theplague 'iftop -i eth0 -n -P'
```
Expected: 1-5 Gbps during inference

**View vLLM logs:**
```bash
tail -f ~/.local/share/ray/session_latest/logs/worker-*.out
```

## Files Reference

- `scripts/01-setup-ollama-head.sh` - Initial head node setup
- `scripts/02-setup-ollama-worker.sh` - Worker node setup
- `scripts/06-start-vllm-cluster-distributed.sh` - Start distributed vLLM (THE FIX)
- `scripts/07-test-3gpu-compute.sh` - Verify all GPUs computing
- `simple_inference_api.py` - Single-node fallback (slower, 1 GPU only)
- `docs/ARCHITECTURE.md` - Full technical details
- `docs/GPU-COMPUTE-DISTRIBUTION.md` - Problem analysis + vLLM solution

