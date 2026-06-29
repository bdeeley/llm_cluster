#!/bin/bash
# 01-start-simple-local-inference.sh
#
# Simple local multi-GPU inference server using transformers + accelerate
# No vLLM/Ray complexity - just direct model loading
#
# Loads: CodeLlama-34B (4-bit) across 2 GPUs with device_map='auto'
# Exposes: OpenAI-compatible API on port 8000

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_DIR="$(dirname "$SCRIPT_DIR")"

MODEL="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
MODELS_DIR="/NVME/MODELS"
HF_CACHE="/NVME/huggingface"

echo "=========================================="
echo "🚀 Local Multi-GPU Inference Server"
echo "=========================================="
echo ""
echo "Setup:"
echo "  GPU0: maxpower RTX 3060 (12GB)"
echo "  GPU1: maxpower Quadro P6000 (24GB)"
echo "  Total: 36GB VRAM"
echo ""
echo "Framework: transformers + accelerate (no vLLM)"
echo "Model:     $MODEL (1.1B - fits on single GPU)"
echo "Server:    http://localhost:8000"
echo ""

# Step 1: Prerequisites
echo "Step 1️⃣  : Checking prerequisites..."
source /home/bdeeley/test/.venv/bin/activate || { echo "  ❌ venv not found"; exit 1; }

pip install -q fastapi uvicorn python-multipart transformers accelerate bitsandbytes 2>/dev/null || true
echo "  ✓ Dependencies ready"

NGPUS=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits | head -1)
echo "  ✓ GPUs found: $NGPUS"
echo ""

# Step 2: Prepare directories
mkdir -p "$MODELS_DIR" "$HF_CACHE" 2>/dev/null || true
echo "Step 2️⃣  : Preparing environment..."
export HF_HOME="$HF_CACHE"
export HF_HUB_CACHE="$HF_CACHE/hub"
export TRANSFORMERS_CACHE="$HF_CACHE/models"
echo "  ✓ Model cache: $MODELS_DIR"
echo ""

# Step 3: Create and run the server
mkdir -p "$CLUSTER_DIR/logs"
LOG_FILE="$CLUSTER_DIR/logs/inference_$(date +%Y%m%d_%H%M%S).log"

echo "Step 3️⃣  : Starting inference server..."
echo "  Logs: $LOG_FILE"
echo ""
echo "  To test:"
echo "    curl -X POST http://localhost:8000/v1/chat/completions \\"
echo "         -H 'Content-Type: application/json' \\"
echo "         -d '{\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}],\"max_tokens\":100}'"
echo ""

# Disable FlashAttention for mixed GPU architectures before Python loads transformers
export FLASH_ATTENTION_2=0
export DISABLE_FLASH_ATTENTION=1

python3 << 'EOFSERVER' 2>&1 | tee "$LOG_FILE"
import os
import torch
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
import uvicorn
from transformers import AutoTokenizer, AutoModelForCausalLM
import json
from datetime import datetime
import asyncio

# Model loads without FlashAttention (env var set in bash script)
os.environ["HF_HOME"] = os.environ.get("HF_HOME", "/NVME/huggingface")

app = FastAPI()

print("=" * 50)
print("Loading model and tokenizer...")
print("=" * 50)

MODEL = "TinyLlama/TinyLlama-1.1B-Chat-v1.0"

try:
    # Load with float16 for efficiency
    tokenizer = AutoTokenizer.from_pretrained(MODEL, trust_remote_code=True)
    print(f"✓ Tokenizer loaded")
    
    # Load model with automatic device placement
    # Use eager attention for mixed GPU architecture (Ampere + Pascal)
    # Load model on cuda:0 (RTX 3060 Ampere) which supports FlashAttention
    model = AutoModelForCausalLM.from_pretrained(
        MODEL,
        torch_dtype=torch.float16,
        device_map="cuda:0",  # Load on Ampere GPU which supports FlashAttention
        attn_implementation="eager",  # Still use eager for compatibility
        trust_remote_code=True,
    )
    
    # Ensure model is in eval mode and set config to disable flash attention
    model.eval()
    if hasattr(model.config, "_flash_attn_2_enabled"):
        model.config._flash_attn_2_enabled = False
    
    print(f"✓ Model loaded on cuda:0 (TinyLlama-1.1B fits on RTX 3060)")
    
except Exception as e:
    print(f"✗ Failed to load model: {e}")
    import traceback
    traceback.print_exc()
    exit(1)
        
except Exception as e:
    print(f"✗ Failed to load model: {e}")
    import traceback
    traceback.print_exc()
    exit(1)

print("\n" + "=" * 50)
print("Model loaded. API ready on http://localhost:8000")
print("=" * 50 + "\n")

@app.get("/health")
async def health():
    return {"status": "ok", "timestamp": datetime.now().isoformat()}

@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [
            {
                "id": MODEL,
                "object": "model",
                "owned_by": "local"
            }
        ]
    }

@app.post("/v1/chat/completions")
def chat_completions(request: dict):
    try:
        messages = request.get("messages", [])
        max_tokens = request.get("max_tokens", 256)
        temperature = request.get("temperature", 0.7)
        
        if not messages:
            raise HTTPException(status_code=400, detail="No messages provided")
        
        # Format prompt for TinyLlama
        prompt_text = ""
        for msg in messages:
            role = msg.get("role", "user")
            content = msg.get("content", "")
            if role == "user":
                prompt_text += f"<|user|>\n{content}<|assistant|>\n"
            else:
                prompt_text += f"{content}\n"
        
        # Tokenize
        inputs = tokenizer(prompt_text, return_tensors="pt").to(model.device)
        
        # Generate with explicit attention settings
        with torch.no_grad():
            # Move inputs to the correct device for each layer
            outputs = model.generate(
                **inputs,
                max_new_tokens=max_tokens,
                temperature=temperature if temperature != 0 else None,
                top_p=0.9 if temperature != 0 else None,
                do_sample=temperature != 0,
            )
        
        # Decode
        generated_text = tokenizer.decode(outputs[0], skip_special_tokens=True)
        response_text = generated_text[len(prompt_text):].strip()
        
        return {
            "id": "chatcmpl-local",
            "object": "chat.completion",
            "created": datetime.now().timestamp(),
            "model": MODEL,
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": response_text
                    },
                    "finish_reason": "stop"
                }
            ],
            "usage": {
                "prompt_tokens": len(inputs.input_ids[0]),
                "completion_tokens": len(outputs[0]) - len(inputs.input_ids[0]),
                "total_tokens": len(outputs[0])
            }
        }
        
    except Exception as e:
        print(f"Error processing request: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")

EOFSERVER
