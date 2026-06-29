#!/usr/bin/env python3
"""
CodeLlama-34B Inference Server (Active-Active Cluster)
Runs on both maxpower and theplague simultaneously
Each host loads the full model independently
"""

import os
import sys
import torch
from datetime import datetime
from transformers import AutoModelForCausalLM, AutoTokenizer
from fastapi import FastAPI, HTTPException
import uvicorn

# Detect hostname
HOSTNAME = os.popen('hostname -s').read().strip()
print(f"\n{'='*70}")
print(f"🚀 CodeLlama-34B Inference Server on {HOSTNAME.upper()}")
print(f"{'='*70}\n")

# Setup environment
os.environ['HF_HOME'] = '/NVME/huggingface'
os.environ['HF_HUB_CACHE'] = '/NVME/huggingface/hub'
os.environ['TRANSFORMERS_CACHE'] = '/NVME/huggingface/models'
os.environ['CUDA_DEVICE_ORDER'] = 'PCI_BUS_ID'
os.environ['CUDA_LAUNCH_BLOCKING'] = '1'

# Per-host config
if 'maxpower' in HOSTNAME.lower():
    os.environ['CUDA_VISIBLE_DEVICES'] = '0,1'  # Both GPUs on maxpower
    MAX_MEMORY = {0: "11GB", 1: "20GB", "cpu": "40GB"}
    PORT = 8000
    print(f"maxpower: Using GPU0 (RTX 3060) + GPU1 (Quadro P6000)")
else:
    os.environ['CUDA_VISIBLE_DEVICES'] = '0'  # Just GPU0 on theplague
    MAX_MEMORY = {0: "11GB", "cpu": "40GB"}
    PORT = 8000
    print(f"theplague: Using GPU0 (RTX 3060)")

app = FastAPI(title="CodeLlama-34B Inference")

# Global model & tokenizer
model = None
tokenizer = None

@app.on_event("startup")
async def startup():
    """Load model on startup"""
    global model, tokenizer
    
    try:
        print("📥 Loading tokenizer...")
        tokenizer = AutoTokenizer.from_pretrained(
            'codellama/CodeLlama-34b-Instruct-hf',
            trust_remote_code=True
        )
        print("✓ Tokenizer loaded")
        
        print(f"📥 Loading CodeLlama-34B on {HOSTNAME}...")
        model = AutoModelForCausalLM.from_pretrained(
            'codellama/CodeLlama-34b-Instruct-hf',
            torch_dtype=torch.float16,
            device_map='auto',
            max_memory=MAX_MEMORY,
            trust_remote_code=True,
            attn_implementation='eager'
        )
        
        # Disable FlashAttention to handle mixed GPU architectures
        if hasattr(model.config, '_flash_attn_2_enabled'):
            model.config._flash_attn_2_enabled = False
        if hasattr(model.config, 'use_flash_attention_2'):
            model.config.use_flash_attention_2 = False
        
        print(f"✓ Model loaded on {HOSTNAME}")
        
        # Show GPU memory
        print(f"\n📊 GPU Memory on {HOSTNAME}:")
        import subprocess
        subprocess.run(['nvidia-smi', '--query-gpu=index,name,memory.used,memory.total', 
                       '--format=csv,noheader,nounits'], capture_output=False)
        
        print(f"\n{'='*70}")
        print(f"✅ {HOSTNAME} Ready for Inference on http://0.0.0.0:{PORT}")
        print(f"{'='*70}\n")
        
    except Exception as e:
        print(f"❌ Startup failed: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

@app.get("/health")
async def health():
    """Health check"""
    return {
        "status": "ok",
        "hostname": HOSTNAME,
        "timestamp": datetime.now().isoformat()
    }

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
                "description": f"CodeLlama-34B (running on {HOSTNAME})"
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
        
        # Format prompt for CodeLlama
        prompt = ""
        for msg in messages:
            role = msg.get("role", "user")
            content = msg.get("content", "")
            if role == "user":
                prompt += f"[INST] {content} [/INST]"
            elif role == "assistant":
                prompt += f" {content}"
        
        # Tokenize
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
    uvicorn.run(app, host="0.0.0.0", port=PORT, log_level="info")
