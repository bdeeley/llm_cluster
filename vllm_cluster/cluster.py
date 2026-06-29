#!/usr/bin/env python3
"""
Distributed CodeLlama-34B Inference Cluster
- maxpower: RTX 3060 GPU0 (12GB)
- theplague: RTX 3060 GPU0 (12GB)
- Total: 24GB VRAM
- Model: CodeLlama-34b-Instruct-hf (~20GB)
- API: OpenAI-compatible on port 8000
"""

import os
import torch
import subprocess
import time
import sys
from datetime import datetime
from transformers import AutoModelForCausalLM, AutoTokenizer
from fastapi import FastAPI, HTTPException
import uvicorn

# Setup environment - RTX 3060 + CPU offloading for CodeLlama-34B
os.environ['HF_HOME'] = '/NVME/huggingface'
os.environ['HF_HUB_CACHE'] = '/NVME/huggingface/hub'
os.environ['TRANSFORMERS_CACHE'] = '/NVME/huggingface/models'
os.environ['CUDA_DEVICE_ORDER'] = 'PCI_BUS_ID'
# DON'T hide GPU1 - we need both for large models
# os.environ['CUDA_VISIBLE_DEVICES'] = '0'  
os.environ['CUDA_LAUNCH_BLOCKING'] = '1'

app = FastAPI(title="CodeLlama-34B Distributed Cluster")

# Global model & tokenizer
model = None
tokenizer = None
device = "cuda"

@app.on_event("startup")
async def startup():
    """Load model on startup"""
    global model, tokenizer
    
    print("\n" + "="*70)
    print("🚀 CodeLlama-34B Distributed Inference Cluster")
    print("="*70)
    print(f"maxpower: RTX 3060 GPU0 (12GB)")
    print(f"theplague: RTX 3060 GPU0 (12GB)")
    print(f"Total VRAM: 24GB")
    print(f"Model: CodeLlama-34b-Instruct-hf (~20GB)")
    print("="*70 + "\n")
    
    try:
        print("📥 Loading tokenizer...")
        tokenizer = AutoTokenizer.from_pretrained(
            'codellama/CodeLlama-34b-Instruct-hf',
            trust_remote_code=True,
            token=os.getenv('HF_TOKEN', None)
        )
        print("✓ Tokenizer loaded")
        
        print("📥 Loading model on maxpower GPU0...")
        print("   (CodeLlama-34B ~20GB will distribute across maxpower's GPUs)")
        
        # CodeLlama-34B is ~20GB
        # maxpower has RTX 3060 (12GB) + Quadro P6000 (24GB) = 36GB total
        # Use device_map='auto' to spread model intelligently across available GPUs
        max_memory = {
            0: "11GB",     # GPU0: RTX 3060
            1: "20GB",     # GPU1: Quadro P6000 (can hold part of model despite being Pascal)
            "cpu": "40GB"  # CPU fallback for any remainder
        }
        
        model = AutoModelForCausalLM.from_pretrained(
            'codellama/CodeLlama-34b-Instruct-hf',
            torch_dtype=torch.float16,
            device_map='auto',
            max_memory=max_memory,
            trust_remote_code=True,
            attn_implementation='eager',
            token=os.getenv('HF_TOKEN', None)
        )
        
        # Disable FlashAttention - required for Ampere/Pascal mixing
        if hasattr(model.config, '_flash_attn_2_enabled'):
            model.config._flash_attn_2_enabled = False
        if hasattr(model.config, 'use_flash_attention_2'):
            model.config.use_flash_attention_2 = False
        
        print("✓ Model loaded on maxpower")
        
        # Show GPU memory
        print("\n📊 GPU Memory (maxpower):")
        subprocess.run(['nvidia-smi', '--query-gpu=index,name,memory.used,memory.total', 
                       '--format=csv,noheader,nounits'], capture_output=False)
        
        # Load on theplague in background
        print("\n🔗 Attempting to load model on theplague GPU0 (background)...")
        load_script = f'''
export HF_HOME=/NVME/huggingface
export CUDA_VISIBLE_DEVICES=0
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_LAUNCH_BLOCKING=1

python3 << 'EOFDIST'
import os, torch
from transformers import AutoModelForCausalLM, AutoTokenizer

os.environ['HF_HOME'] = '/NVME/huggingface'
os.environ['CUDA_VISIBLE_DEVICES'] = '0'

print("[theplague] Loading CodeLlama-34B...")
tokenizer = AutoTokenizer.from_pretrained('codellama/CodeLlama-34b-Instruct-hf', trust_remote_code=True)

max_memory = {{0: "11GB", "cpu": "40GB"}}
model = AutoModelForCausalLM.from_pretrained('codellama/CodeLlama-34b-Instruct-hf',
    torch_dtype=torch.float16, device_map='auto', max_memory=max_memory, 
    trust_remote_code=True, attn_implementation='eager')

if hasattr(model.config, '_flash_attn_2_enabled'):
    model.config._flash_attn_2_enabled = False
if hasattr(model.config, 'use_flash_attention_2'):
    model.config.use_flash_attention_2 = False

print("[theplague] ✓ Model loaded on GPU0")

import subprocess
print("[theplague] GPU Memory:")
subprocess.run(['nvidia-smi', '--query-gpu=index,name,memory.used,memory.total', 
               '--format=csv,noheader,nounits'])

import time
while True:
    time.sleep(60)
EOFDIST
'''
        
        try:
            proc = subprocess.Popen(
                ['ssh', '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=5', 
                 'bdeeley@172.16.0.62', load_script],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            # Give it a moment to start
            time.sleep(3)
            # Check if it's still running
            if proc.poll() is None:
                print("✓ theplague loading in background")
            else:
                stdout, stderr = proc.communicate()
                print(f"⚠ theplague SSH failed (continuing with maxpower only)")
                if stderr:
                    print(f"  Error: {stderr.decode()[:200]}")
        except Exception as e:
            print(f"⚠ Warning: Could not start theplague load: {e}")
            print("  (continuing with maxpower only)")
        
        print("\n" + "="*70)
        print("✅ Startup complete - Ready for inference")
        print("="*70 + "\n")
        
    except Exception as e:
        print(f"\n❌ Startup failed: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

@app.get("/health")
async def health():
    """Health check"""
    return {"status": "ok", "timestamp": datetime.now().isoformat()}

@app.get("/v1/models")
async def list_models():
    """List available models"""
    return {
        "object": "list",
        "data": [
            {
                "id": "codellama/CodeLlama-34b-Instruct-hf",
                "object": "model",
                "owned_by": "meta",
                "description": "CodeLlama-34B (distributed: maxpower RTX 3060 GPU0 + CPU offload)"
            }
        ]
    }

@app.post("/v1/chat/completions")
async def chat_completions(request: dict):
    """OpenAI-compatible chat completions"""
    if not model or not tokenizer:
        raise HTTPException(status_code=503, detail="Model not loaded")
    
    try:
        messages = request.get("messages", [])
        if not messages:
            raise HTTPException(status_code=400, detail="No messages provided")
        
        # Format prompt for Mistral
        prompt = ""
        for msg in messages:
            role = msg.get("role", "user")
            content = msg.get("content", "")
            if role == "user":
                prompt += f"[INST] {content} [/INST]"
            elif role == "assistant":
                prompt += f" {content}"
        
        # Tokenize (returns dict with 'input_ids' and 'attention_mask')
        encoding = tokenizer(prompt, return_tensors="pt")
        input_ids = encoding['input_ids'].to(next(model.parameters()).device)
        attention_mask = encoding['attention_mask'].to(next(model.parameters()).device)
        
        max_tokens = request.get("max_tokens", 128)
        temperature = request.get("temperature", 0.7)
        
        # Generate
        with torch.no_grad():
            outputs = model.generate(
                input_ids=input_ids,
                attention_mask=attention_mask,
                max_new_tokens=min(max_tokens, 256),
                temperature=max(temperature, 0.1) if temperature != 0 else 1.0,
                top_p=0.9,
                do_sample=temperature > 0,
                pad_token_id=tokenizer.eos_token_id
            )
        
        # Decode response
        full_response = tokenizer.decode(outputs[0], skip_special_tokens=True)
        response_text = full_response[len(prompt):].strip()
        
        return {
            "id": "chatcmpl-local",
            "object": "chat.completion",
            "created": datetime.now().timestamp(),
            "model": "codellama/CodeLlama-34b-Instruct-hf",
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
                "prompt_tokens": input_ids.shape[1],
                "completion_tokens": outputs.shape[1] - input_ids.shape[1],
                "total_tokens": outputs.shape[1]
            }
        }
        
    except HTTPException:
        raise
    except Exception as e:
        print(f"❌ Error in /v1/chat/completions: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    print("\n" + "="*70)
    print("Starting API Server")
    print("  Health:  http://localhost:8000/health")
    print("  Models:  http://localhost:8000/v1/models")
    print("  Chat:    http://localhost:8000/v1/chat/completions (POST)")
    print("="*70 + "\n")
    
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")
