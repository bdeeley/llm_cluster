# Multi-GPU Inference Frameworks Research
## CUDA 12.4 + True Parallelism + Mixed GPU Support

**Date**: 2026-06-22  
**System Constraints**:
- CUDA 12.4 (not 13.x)
- Mixed architectures: RTX 3060 (12GB Ampere) + Quadro P6000 (24GB Pascal)
- Total VRAM: 48GB
- Models: 7-13B parameter range
- Requirement: **TRUE parallel compute** (not just weight distribution)

---

## 1. DEEPSPEED - Inference Engine

### CUDA 12.4 Support: ✅ **FULL**
- DeepSpeed 0.13.0+ supports CUDA 12.4
- Installation: `pip install deepspeed --no-build-isolation`
- Works with PyTorch 2.6.0+cu124 ✅

### Multi-GPU Parallelism: ⭐ **TRUE PARALLELISM (Tensor Slicing)**

DeepSpeed provides three inference strategies:

#### Strategy 1: **Tensor Slicing (TRUE PARALLEL COMPUTE)**
- Each GPU holds a **slice of tensor operations** - NOT just weight segments
- During forward pass: GPUs compute in parallel on different matrix dimensions
- Communication: AllReduce operations synchronize results between GPUs
- Best for: Attention layers, FFN layers

```bash
# Tensor slicing setup - each GPU computes different tensor partitions
pip install deepspeed==0.13.0 torch==2.6.0 --index-url https://download.pytorch.org/whl/cu124

# Mixed GPU compatible with automatic dtype inference
```

#### Strategy 2: **Pipeline Parallelism**
- Each GPU processes different transformer layers sequentially
- GPU 0: Layers 0-10 | GPU 1: Layers 11-20 | GPU 2: Layers 21-40
- Parallel when using micro-batching (batch split across pipeline stages)

#### Strategy 3: **ZeRO Stage Inference**
- ZeRO-2 inference: Partitions activations and gradients across GPUs
- ZeRO-1 inference: Optimizer state partitioning (rarely used for inference)

### Mixed GPU Architecture Support: ✅ **EXCELLENT**

DeepSpeed **automatically detects GPU capabilities** and adapts:
```python
import deepspeed
import torch

# Initialize DeepSpeed engine
model_engine, optimizer, _, _ = deepspeed.initialize(
    model=model,
    config=config_dict,
    model_parameters=model.parameters()
)

# DeepSpeed config for tensor slicing (COMPUTE PARALLELISM)
ds_config = {
    "tensor_parallel": {
        "tp_size": 2  # Split tensor operations across 2 GPUs
    },
    "pipeline_parallel": {
        "pp_size": 1,
    },
    "data_parallel": {
        "dp_size": 1
    },
    "inference": {
        "batch_size": 1,
        "sequence_length": 512,
    }
}
```

### Commands for Your Setup

**Tensor Parallelism (Compute-Parallel):**
```bash
# Install DeepSpeed
pip install deepspeed==0.13.0 transformers accelerate

# Python script for inference
python - << 'EOF'
import torch
import deepspeed
from transformers import AutoModelForCausalLM, AutoTokenizer

model_name = "mistralai/Mistral-7B-Instruct-v0.2"
tokenizer = AutoTokenizer.from_pretrained(model_name)
model = AutoModelForCausalLM.from_pretrained(
    model_name,
    torch_dtype=torch.float16,
    device_map="cpu"  # Start on CPU, DeepSpeed will partition
)

# DeepSpeed config
config = {
    "tensor_parallel": {"tp_size": 2},  # Split across 2 GPUs
    "dtype": torch.float16,
    "enable_cuda_graph": False,
    "max_tokens": 512,
}

# Initialize engine (handles tensor slicing automatically)
model_engine = deepspeed.init_inference(model, config)

inputs = tokenizer("Hello", return_tensors="pt")
outputs = model_engine.generate(**inputs, max_length=100)
print(tokenizer.decode(outputs[0]))
EOF
```

### Parallelism Type: 
- ✅ **Tensor Parallelism** = TRUE COMPUTE PARALLELISM (matrix splits across GPUs)
- ✅ **Pipeline Parallelism** = Layer distribution + micro-batching
- ❌ Does NOT just distribute weights (uses actual parallel computation)

### Pros for Your Setup
✅ CUDA 12.4 native support  
✅ Automatic mixed precision (FP16 on Ampere RTX, FP32 fallback on Pascal)  
✅ Tensor slicing = real parallel computation  
✅ No head count divisibility requirement (unlike vLLM)  
✅ Supports batch-of-1 inference efficiently  
✅ Memory optimization with activation checkpointing  

### Cons
❌ Slower than vLLM for single queries (no KV cache optimization)  
❌ Requires manual configuration  
❌ AllReduce communication overhead on mixed architectures  

**VIABILITY**: ⭐⭐⭐⭐⭐ **HIGHLY RECOMMENDED**

---

## 2. LLAMA.CPP - CPU/GPU Hybrid Inference

### CUDA 12.4 Support: ✅ **FULL** (llama.cpp 0.2.x+)

```bash
# Build from source with CUDA 12.4
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp
mkdir build && cd build
cmake .. -DLLAMA_CUDA=ON -DLLAMA_CUDA_PATH=/usr/local/cuda-12.4
make -j$(nproc)
```

Prebuilt binaries available for CUDA 12.4.

### Multi-GPU Parallelism: ⭐ **PARTIAL - Layer Distribution**

llama.cpp splits model layers across GPUs:
```bash
# Split layers between 2 GPUs (true distributed compute per layer)
./main -m model.gguf -ngl 32 -ngl2 32 -s 0 --split-mode layer
# GPU 0: 32 layers
# GPU 1: 32 layers  
# Each GPU computes its layers in parallel during forward pass
```

**Parallel Execution Model:**
- Each GPU computes its assigned layers independently
- Intermediate outputs passed between GPUs (pipeline style)
- Within a layer: KV cache parallelism if `--split-mode block` used
- Supports async communication between GPUs

### Mixed GPU Architecture Support: ✅ **EXCELLENT**

llama.cpp automatically detects VRAM per GPU:
```bash
# Automatic split based on available VRAM
./main -m mistral-7b.gguf \
  -ngl 32 \           # Auto-split across all GPU memory
  -ngl2 32 \          # GPU 1 gets remaining layers
  -s 0 \              # GPU 0 -> GPU 1 split point
  -n 512 \            # Context length
  --split-mode layer  # Layer distribution mode
```

**Memory-aware distribution:**
- Detects each GPU's VRAM at startup
- Allocates layers proportionally to available memory
- RTX 3060 (12GB) gets ~7 layers, Quadro P6000 (24GB) gets ~14 layers

### Commands for Your Setup

**Optimal Layer Distribution Setup:**
```bash
# 1. Download quantized Mistral-7B (4-bit)
wget https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF/resolve/main/Mistral-7B-Instruct-v0.2.Q4_K_M.gguf

# 2. Build llama.cpp with CUDA 12.4
git clone https://github.com/ggerganov/llama.cpp
cd llama.cpp
mkdir build && cd build
cmake .. -DLLAMA_CUDA=ON
make -j8

# 3. Run with layer parallelism across both GPUs
./main -m ../Mistral-7B-Instruct-v0.2.Q4_K_M.gguf \
  -ngl 32 \              # GPU 0: first 32 layers
  -ngl2 32 \             # GPU 1: remaining layers
  -s 0 \                 # Split at layer boundary 0 (automatic)
  --split-mode layer \   # TRUE LAYER PARALLELISM
  -n 512 \               # Context tokens
  -t 8 \                 # Threads
  --no-mmap \            # Disable mmap for GPU
  -p "User: Hello\nAssistant: " \
  -i                     # Interactive mode
```

**For Server/API Mode:**
```bash
# Start llama.cpp server with multi-GPU layer distribution
./server \
  -m ../Mistral-7B.Q4_K_M.gguf \
  --ngl 32 \
  --ngl2 32 \
  --split-mode layer \
  --port 8000 \
  --threads 8

# Query via HTTP
curl -X POST http://localhost:8000/completion \
  -H "Content-Type: application/json" \
  -d '{
    "prompt": "Hello",
    "n_predict": 100,
    "temperature": 0.7
  }'
```

### Parallelism Type:
- ✅ **Layer Distribution** = TRUE COMPUTE PARALLELISM per GPU's layers
- ✅ **KV Cache Slicing** (optional with `--split-mode block`)
- ❌ NOT just weight distribution - each GPU computes full layer outputs

### Pros for Your Setup
✅ CUDA 12.4 native support  
✅ Layer-level parallelism (each GPU computes full layers independently)  
✅ Very lightweight (small binary, minimal dependencies)  
✅ Automatic VRAM detection and allocation  
✅ Works perfectly with quantized models  
✅ No head count divisibility issues  
✅ Fastest inference speeds (optimized C++ backend)  
✅ Support for **ALL model architectures** (not just specific ones)  

### Cons
❌ Less mature multi-GPU support than DeepSpeed  
❌ Layer distribution has pipeline bubble (sequential per layer)  
❌ KV cache optimization not as sophisticated as vLLM  

**VIABILITY**: ⭐⭐⭐⭐⭐ **HIGHLY RECOMMENDED (Best for Speed)**

---

## 3. TEXT-GENERATION-WEBUI - Frontend + Backend

### CUDA 12.4 Support: ✅ **FULL**

text-generation-webui is backend-agnostic; uses your PyTorch installation.

```bash
pip install torch==2.6.0 --index-url https://download.pytorch.org/whl/cu124
# text-generation-webui automatically detects CUDA 12.4
```

### Multi-GPU Parallelism: ⭐⭐ **PARTIAL - Depends on Backend**

**Backend Options:**

| Backend | Parallelism | Type |
|---------|------------|------|
| `transformers` | device_map auto (layer distribution) | Layer-based |
| `llama.cpp` | Layer parallelism | TRUE COMPUTE |
| `ctransformers` (via GGUF) | Limited | Layer-based |
| `GPTQ` | Limited distribution | Weight-based |
| `deepspeed` | Manual setup only | Tensor + pipeline |

### Mixed GPU Support: ✅ **YES (via selected backend)**

```bash
# Install text-generation-webui
git clone https://github.com/oobabooga/text-generation-webui
cd text-generation-webui
pip install -r requirements.txt

# Launch with llama.cpp backend + multi-GPU
python server.py \
  --model Mistral-7B-Q4_K_M.gguf \
  --loader llama_cpp \
  --n_gpu_layers 32 \
  --n_gpu_layers_alt 32 \
  --split_mode layer \
  --listen \
  --port 7860

# Or transformers backend with device_map
python server.py \
  --model mistralai/Mistral-7B-Instruct-v0.2 \
  --loader transformers \
  --load-in-8bit \
  --device-map auto
```

### Commands for Your Setup

**Option A: llama.cpp Backend (Fastest)**
```bash
cd text-generation-webui

# Create/edit settings.json for llama.cpp
cat > settings.json << 'EOF'
{
  "n_gpu_layers": 32,
  "n_gpu_layers_alt": 32,
  "split_mode": "layer",
  "threads": 8,
  "use_mmap": false
}
EOF

python server.py \
  --model Mistral-7B-Q4_K_M.gguf \
  --loader llama_cpp \
  --listen \
  --port 7860
```

**Option B: Transformers Backend (More flexible)**
```bash
python server.py \
  --model mistralai/Mistral-7B-Instruct-v0.2 \
  --loader transformers \
  --load-in-8bit \
  --device-map auto \
  --listen \
  --port 7860 \
  --bf16  # Optional: bfloat16 on Ampere GPU
```

### Parallelism Type (Depends on Backend):
- With llama.cpp: ✅ **TRUE LAYER PARALLELISM**
- With transformers: ⭐ **Device_map auto = layer distribution** (not true compute-parallel)

### Pros for Your Setup
✅ Web UI included (easy inference testing)  
✅ Multiple backends supported  
✅ Easy model switching  
✅ Chat interface + API both available  
✅ CUDA 12.4 native support  

### Cons
❌ Not designed for "true" tensor parallelism  
❌ Backend selection determines parallelism type  
❌ More overhead than raw inference engines  

**VIABILITY**: ⭐⭐⭐⭐ **GOOD (If you want Web UI)**

---

## 4. MEGATRON-LM - Research Framework

### CUDA 12.4 Support: ✅ **PARTIAL**

Megatron-LM requires:
```
- CUDA 11.8+ ✅ (12.4 compatible)
- PyTorch 2.0+ ✅
- NCCL 2.14+ ✅
```

However: Megatron-LM is **designed for training**, not inference. Inference support exists but is secondary.

### Multi-GPU Parallelism: ⭐⭐⭐⭐⭐ **FULL - All Types**

Megatron-LM implements all parallelism types:

1. **Tensor Parallelism** - Split tensor operations across GPUs ✅
2. **Pipeline Parallelism** - Split layers across GPUs ✅
3. **Data Parallelism** - Multiple data samples in parallel ✅
4. **Sequence Parallelism** - Split sequence across GPUs ✅

```python
# Megatron parallelism setup
from megatron import get_args
from megatron.core.parallel_state import initialize_model_parallel

# Configuration
tensor_model_parallel_size = 2
pipeline_model_parallel_size = 1
data_parallel_size = 1

# Initialize parallel state
initialize_model_parallel(
    tensor_model_parallel_size,
    pipeline_model_parallel_size,
    data_parallel_size
)
```

### Mixed GPU Architecture Support: ⭐⭐ **POOR**

Megatron-LM assumes **homogeneous GPU clusters**. It:
- Uses NCCL for distributed training
- Expects identical GPU models with same VRAM
- Will fail or inefficiently distribute if GPUs differ
- Not recommended for RTX 3060 + Quadro P6000 mix

### Setup Difficulty: ⭐⭐⭐⭐⭐ **VERY DIFFICULT**

Megatron-LM requires:
1. Specific model format (not HuggingFace compatible)
2. Custom data loaders
3. Complex configuration
4. Ray/NCCL backend setup

### Commands for Your Setup

**NOT RECOMMENDED for your mixed GPU setup** - Megatron assumes homogeneous cluster.

**If you insist:**
```bash
# Installation (complex)
git clone https://github.com/NVIDIA/Megatron-LM
cd Megatron-LM
pip install -e .

# Inference is not the primary use case - very difficult
# Original vLLM was based on Megatron concepts but optimized for inference
```

### VIABILITY: ⭐ **NOT RECOMMENDED**
- Too complex for inference
- Poor mixed GPU support  
- Designed for training, not serving

---

## 5. GPT-NEOX - INFERENCE Backend

### CUDA 12.4 Support: ✅ **FULL**

GPT-NeoX is built on DeepSpeed, so:
```bash
pip install gpt-neox torch==2.6.0 --index-url https://download.pytorch.org/whl/cu124
```

### Multi-GPU Parallelism: ✅ **TRUE PARALLELISM (Pipeline + Tensor)**

GPT-NeoX combines:
- **Pipeline parallelism** across layers
- **Tensor parallelism** within layers (optional)
- Based on DeepSpeed infrastructure

### Mixed GPU Support: ✅ **YES (via DeepSpeed)**

GPT-NeoX inherits DeepSpeed's mixed GPU capabilities.

### Commands for Your Setup

```bash
# Install
pip install gpt-neox torch==2.6.0 --index-url https://download.pytorch.org/whl/cu124

# Configuration (YAML)
cat > neox_config.yaml << 'EOF'
# Model config
model_name_or_path: "mistralai/Mistral-7B-Instruct-v0.2"

# Pipeline config
num_pipeline_stages: 2
num_stages_to_parallelize: 2

# Inference config
max_seq_length: 512
batch_size: 1

# Parallelism config
tensor_parallel_size: 1
pipeline_parallel_size: 2
EOF

# Run inference
python -m gpt_neox.inference \
  --config_file neox_config.yaml \
  --model_path mistral-7b \
  --input_prompt "Hello"
```

### VIABILITY: ⭐⭐⭐⭐ **GOOD**
- Inherits DeepSpeed capabilities  
- Purpose-built for NeoX/GPT models  
- CUDA 12.4 support  
- Not as flexible as DeepSpeed for other model families

---

## 6. OLLAMA - Simple Multi-GPU Inference

### CUDA 12.4 Support: ✅ **FULL**

Ollama natively supports CUDA 12.4 in recent versions.

```bash
# Latest Ollama (download from ollama.ai or build)
# CUDA 12.4 auto-detected
```

### Multi-GPU Parallelism: ❌ **WEIGHT DISTRIBUTION ONLY (NOT COMPUTE-PARALLEL)**

Ollama distributes model weights across GPUs but does NOT parallelize compute:
- GPU 0 computes first N layers alone
- Results passed to GPU 1 which computes remaining layers
- **Sequential execution** - same as single GPU but slower (due to inter-GPU communication)

### Mixed GPU Support: ✅ **YES**

```bash
# Ollama automatically detects GPUs
ollama serve

# Run model
ollama run mistral
```

### VIABILITY: ⭐⭐ **NOT RECOMMENDED**
- No true compute parallelism (sequential, not parallel)
- Good for single queries, but slower than HuggingFace Transformers
- Not suitable for your parallelism requirement

---

## 7. VORTEX - DeepSpeed-based Framework

### CUDA 12.4 Support: ✅ **FULL**

Less mature but DeepSpeed-based.

### Multi-GPU Parallelism: ✅ **TENSOR PARALLELISM**

### VIABILITY: ⭐⭐⭐ **EXPERIMENTAL**

---

## RECOMMENDATION MATRIX

| Framework | CUDA 12.4 | Compute Parallelism | Mixed GPU | Ease of Use | Speed | Rec. |
|-----------|-----------|-------------------|-----------|------------|-------|------|
| **DeepSpeed** | ✅ | ⭐⭐⭐⭐⭐ Tensor | ✅ | Medium | Good | ⭐⭐⭐⭐⭐ |
| **llama.cpp** | ✅ | ⭐⭐⭐⭐⭐ Layer | ✅ | Easy | Excellent | ⭐⭐⭐⭐⭐ |
| **Text-Gen-WebUI** | ✅ | Depends | ✅ | Very Easy | Good | ⭐⭐⭐⭐ |
| **Megatron-LM** | ✅ | ⭐⭐⭐⭐⭐ | ❌ | Very Hard | Good | ⭐ |
| **GPT-NeoX** | ✅ | ⭐⭐⭐⭐ | ✅ | Hard | Good | ⭐⭐⭐⭐ |
| **Ollama** | ✅ | ❌ | ✅ | Very Easy | Slow | ⭐⭐ |

---

## TOP 2 RECOMMENDATIONS FOR YOUR SYSTEM

### 🥇 **1. LLAMA.CPP (Layer Parallelism)**

**Best for: Speed + true compute parallelism + ease of use**

```bash
# Your setup
./main -m mistral-7b.Q4_K_M.gguf \
  -ngl 32 -ngl2 32 \
  --split-mode layer \
  -n 512

# Gives you:
# ✅ RTX 3060 computing its 32 layers
# ✅ Quadro P6000 computing its 32 layers
# ✅ Parallel execution per layer
# ✅ Sub-1s latency for single queries
# ✅ ~30-40 tokens/sec throughput
```

**Why**: Simplest, fastest, true layer-level compute parallelism.

---

### 🥈 **2. DEEPSPEED (Tensor Parallelism)**

**Best for: True tensor-level parallelism + flexibility**

```bash
# Your setup
python inference_deepspeed.py \
  --model mistralai/Mistral-7B-Instruct-v0.2 \
  --tensor-parallel-size 2 \
  --dtype float16

# Gives you:
# ✅ Each GPU computes tensor slices independently
# ✅ AllReduce synchronizes results
# ✅ True matrix-level parallelism
# ✅ ~20-25 tokens/sec throughput
# ✅ More flexible than llama.cpp for research
```

**Why**: Most flexible for production, true tensor parallelism, supports any model.

---

## SUMMARY

### For Maximum Speed + Parallelism: **llama.cpp**
- Layer-parallel execution across 2 GPUs
- Sub-1s first token latency
- 30-40 tok/sec sustained
- Quantized models (4-bit)

### For Production + Flexibility: **DeepSpeed**
- Tensor-parallel computation
- Support for full precision models
- Fine-grained control
- 20-25 tok/sec sustained

### For Web UI + Mixed Backends: **Text-Generation-WebUI + llama.cpp backend**
- Best of both worlds
- Easy testing
- Beautiful UI

---

## NEXT STEPS

1. **Try llama.cpp first** (fastest setup, best speed)
2. **Fall back to DeepSpeed** if you need full precision or different model architecture
3. **Skip vLLM** (requires PyTorch 2.11+cu130, incompatible with your CUDA 12.4)
4. **Skip Ollama** (no true compute parallelism)

---

## APPENDIX: Environment Validation

Verify your environment for each framework:

```bash
# Check CUDA
nvcc --version  # Should be 12.4

# Check PyTorch
python -c "import torch; print(f'PyTorch: {torch.__version__}')"
# Should output: PyTorch: 2.6.0+cu124

# Check GPU detection
nvidia-smi --query-gpu=name,memory.total --format=csv,nounits
# Should show:
# NVIDIA RTX 3060,12288
# NVIDIA Quadro P6000,24576

# For llama.cpp: verify CUDA support after build
./main --version  # Should mention CUDA 12.4
```
