# vLLM Multi-Node Distributed Exploration

## Architecture Overview
```
Ray Head Node (maxpower:6379)
├─ Ray Worker 1 (maxpower:6380) - GPU 0,1
├─ Ray Worker 2 (theplague:6380) - GPU 0
└─ vLLM Engine (runs on Ray workers)
    ├─ Tensor Parallel across workers
    └─ OpenAI API on master
```

## Deployment Plan

### Phase 1: Single-Node vLLM (Validation)
1. Install vLLM + dependencies on maxpower
2. Test single GPU: `python -m vllm.entrypoints.openai.api_server --model meta-llama/Llama-2-7B-hf`
3. Verify `/v1/chat/completions` works
4. Check VRAM consumption with nvidia-smi

### Phase 2: Local Ray Cluster
1. Start Ray head on maxpower
2. Start Ray worker on local machine (same node)
3. Run vLLM with `tensor_parallel_size=2` (split across 2 GPUs)
4. Verify VRAM split (each GPU gets ~50% of model)

### Phase 3: Multi-Node Ray Cluster
1. Start Ray head on maxpower
2. SSH to theplague, start Ray worker joining maxpower cluster
3. vLLM: `tensor_parallel_size=3` (distribute across all 3 GPUs)
4. Test with 48GB model across 60GB pool

### Phase 4: Model Selection
- **Available**: HuggingFace quantized models (GPTQ, AWQ)
- **Target**: Llama-2-70B or Mistral-large (works at 48GB)
- **Test**: Same model used in exo for comparison

---

## Commands for Testing

### Install vLLM
```bash
pip install vllm ray torch transformers
```

### Start Ray cluster
```bash
# Node 1 (maxpower) - Head
ray start --head --port=6379

# Node 2 (theplague) - Worker
ray start --address='<maxpower-ip>:6379'

# Check status
ray status
```

### Run vLLM with tensor parallel
```bash
python -m vllm.entrypoints.openai.api_server \
  --model meta-llama/Llama-2-70B-chat-hf \
  --tensor-parallel-size 3 \
  --pipeline-parallel-size 1 \
  --gpu-memory-utilization 0.9
```

### Test inference
```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "meta-llama/Llama-2-70B-chat-hf",
    "messages": [{"role": "user", "content": "hi"}],
    "max_tokens": 100
  }'
```

### Monitor VRAM
```bash
watch -n 1 nvidia-smi
```

---

## Risks & Unknowns

1. **Ray Network Overhead**: libp2p vs Ray's TCP - how much slower?
2. **Tensor Parallel Efficiency**: At 48GB model + 60GB pool, will achieve good utilization?
3. **Model Format**: Need CUDA-compatible formats (GPTQ/AWQ), not MLX
4. **SSH Key Auth**: theplague needs passwordless SSH from maxpower for Ray worker join

---

## Success Metrics

- [ ] VRAM increases to 90%+ when model loads
- [ ] Inference response time < 5s for first token
- [ ] All 3 GPU devices report load via nvidia-smi
- [ ] Multi-query shows tensor distribution (GPU memory unequal by design)

---

**Estimated Setup Time**: 2-3 hours  
**Go/No-Go Decision**: After Phase 2 completion
