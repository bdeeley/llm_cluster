# vLLM Multi-Node Deployment

## Quick Start

```bash
# Make scripts executable
chmod +x *.sh

# Full automated setup
./00-deploy.sh

# Or step-by-step:
./01-setup-ray.sh        # Start Ray head on maxpower
./03-add-theplague.sh    # Connect theplague worker
./02-start-vllm.sh 3     # Start vLLM with 3-GPU tensor parallel
./04-test-vllm.sh        # Test inference
```

## Architecture

```
Ray Head (maxpower:6379)
├─ GPU 0 (RTX 3060 12GB)
├─ GPU 1 (Quadro P6000 24GB)
└─ Ray Worker (theplague:6379 - joined)
   └─ GPU 0 (RTX 3060 12GB)

vLLM Server: http://0.0.0.0:8000
└─ Tensor Parallel Distribution (model shards across 3 GPUs)
```

## Monitoring

```bash
# Ray cluster status
ray status

# GPU VRAM usage
nvidia-smi

# Live monitoring
watch -n 1 nvidia-smi
```

## Expected Results

- **VRAM Consumption**: Model loads → VRAM increases to 70-90%
- **Multi-GPU**: All 3 GPUs show compute/memory load
- **Inference**: `/v1/chat/completions` returns tokens in <5s
- **Process Visibility**: vllm processes visible in `ps aux`

## Differences from exo

| Aspect | exo | vLLM |
|--------|-----|------|
| Process Model | Actor (state machine) | Subprocess (traditional) |
| Multi-Node | libp2p gossip | Ray RPC |
| VRAM Tracking | Broken (0MB) | Transparent (actual usage) |
| Tensor Parallel | Pipeline-based | Explicit sharding |
| Community | Small | Large (production use) |

## Troubleshooting

**Ray workers not connecting**:
```bash
# Check SSH passwordless auth from maxpower to theplague
ssh bdeeley@172.16.0.29 echo "OK"

# Check Ray head is listening
ray status
```

**vLLM hangs on model load**:
```bash
# Model may be downloading from HF
# Check if huggingface cache is accessible
df -h ~/.cache/huggingface/

# Or monitor on theplague
ssh bdeeley@172.16.0.29 'watch -n 1 nvidia-smi'
```

**No VRAM usage**:
- Check `ray status` - all workers connected?
- Check vLLM logs for tensor parallel errors
- Verify model is valid (try smaller model first)

---

**Goal**: Prove distributed inference works with real VRAM consumption
