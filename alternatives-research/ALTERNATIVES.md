# Distributed LLM Inference Alternatives to exo

## Candidates Under Review

### 1. vLLM (Ray-backed distributed)
**Status**: ACTIVE - Mature, widely used, OpenAI-compatible  
**Distributed**: ✅ YES - Ray backend for multi-node  
**OpenAI API**: ✅ YES - `/v1/chat/completions`  
**MLX Support**: ❌ NO (PyTorch/CUDA only)  
**VRAM Transparency**: ✅ YES - Actual processes spawn  
**Complexity**: MEDIUM  

**Pros**:
- Battle-tested in production
- Explicit process spawning (not state machine)
- Ray provides robust distributed scheduling
- High throughput optimization

**Cons**:
- No MLX backend (requires PyTorch)
- Requires Ray cluster setup
- CUDA memory management can be finicky

**Research**: Check vLLM + Ray on NVIDIA CUDA

---

### 2. Ray LLM (Ray native)
**Status**: EXPERIMENTAL/EMERGING  
**Distributed**: ✅ YES - Native Ray  
**OpenAI API**: ✅ Partial  
**MLX Support**: ❌ NO  
**Complexity**: MEDIUM-HIGH  

**Pros**:
- Direct Ray integration
- Horizontal scaling built-in

**Cons**:
- Less mature than vLLM
- Still evolving APIs

---

### 3. TensorRT-LLM (NVIDIA native)
**Status**: PRODUCTION  
**Distributed**: ✅ YES - NVIDIA's distributed tensor parallelism  
**OpenAI API**: ⚠️ PARTIAL (needs Triton Inference Server)  
**MLX Support**: ❌ NO  
**Complexity**: HIGH  

**Pros**:
- Best performance on NVIDIA GPUs
- Explicit tensor parallelism sharding
- Production-grade reliability

**Cons**:
- Complex deployment (Triton server required)
- CUDA-only, no MLX
- Steep learning curve

---

### 4. DeepSpeed Inference
**Status**: ACTIVE  
**Distributed**: ✅ YES - Tensor parallel + pipeline parallel  
**OpenAI API**: ❌ NO (manual HTTP wrapper needed)  
**MLX Support**: ❌ NO  
**Complexity**: HIGH  

**Pros**:
- SOTA distributed training/inference
- Optimized pipeline parallelism
- Microsoft-backed

**Cons**:
- No OpenAI API out-of-box
- Complex configuration
- CUDA/PyTorch only

---

### 5. Ollama Cluster (Limited)
**Status**: STABLE  
**Distributed**: ⚠️ PARTIAL (multi-model, not multi-node sharding)  
**OpenAI API**: ✅ YES  
**MLX Support**: ⚠️ PARTIAL (Mac only for MLX)  
**Complexity**: LOW  

**Pros**:
- Dead simple setup
- Works locally on Linux

**Cons**:
- NOT truly distributed (can't split model across nodes)
- Single-node architecture
- Model must fit on one GPU

---

### 6. LiteLLM Proxy + vLLM
**Status**: ACTIVE  
**Distributed**: ✅ (vLLM backend is distributed)  
**OpenAI API**: ✅ YES  
**MLX Support**: ❌ NO  
**Complexity**: MEDIUM  

**Pros**:
- Simple proxy layer
- Flexible backend swapping
- Good for existing vLLM deployments

**Cons**:
- Not a new solver, just a wrapper

---

### 7. MLC-LLM (Alternative to exo, same MLX)
**Status**: ACTIVE  
**Distributed**: ⚠️ PARTIAL (supports multi-device, limited multi-node)  
**OpenAI API**: ⚠️ EXPERIMENTAL  
**MLX Support**: ✅ YES (native MLX backend)  
**VRAM Transparency**: ✅ YES  
**Complexity**: MEDIUM  

**Pros**:
- Same MLX backend as exo (avoids PyTorch)
- Active development
- Actually spawns real processes
- Web UI + API

**Cons**:
- Distributed story weaker than vLLM
- Smaller community
- Multi-node less tested

---

### 8. VLLM + MLX via PyTorch bridge (HYBRID)
**Status**: EXPERIMENTAL  
**Distributed**: ✅ YES (vLLM)  
**OpenAI API**: ✅ YES  
**MLX Support**: ⚠️ VIA BRIDGE  
**Complexity**: MEDIUM-HIGH  

**Pros**:
- Get vLLM reliability + MLX model support
- Bridge MLX models through PyTorch tensor format

**Cons**:
- Requires model format conversion
- Extra latency from bridge
- Not officially supported

---

## Recommendation Priority

### 🥇 Primary: vLLM (CUDA only)
- Most mature distributed inference
- Battle-tested at scale
- Trade-off: No MLX, must use PyTorch quantized models

### 🥈 Secondary: MLC-LLM (MLX native, limited distributed)
- Keep using MLX ecosystem
- Real process spawning
- But needs to prove multi-node reliability

### 🥉 Tertiary: TensorRT-LLM (High complexity, best perf)
- Only if performance critical
- Requires Triton deployment
- Worth exploring for 60GB cluster optimization

---

## Next Steps

1. **vLLM Test**: Deploy vLLM on maxpower/theplague cluster with PyTorch Llama models
2. **MLC-LLM Investigation**: Test distributed capabilities, multi-node configuration
3. **TensorRT-LLM PoC**: Build minimal Triton + TRT-LLM pipeline

---

**Created**: 2026-06-21  
**Session**: Exploring alternatives after exo runner state machine blocker
