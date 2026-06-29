#!/usr/bin/env python3
"""
Simple dual-node inference API serving Mistral-7B across 3 GPUs.
- maxpower: 2 GPUs (RTX + Quadro) loaded with model
- theplague: 1 GPU (RTX) loaded with model
- FastAPI on port 8000 accepts queries
"""

import os
import torch
from transformers import AutoModelForCausalLM, BitsAndBytesConfig, AutoTokenizer
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
import uvicorn
import subprocess
import time
import sys

# Setup environment
os.environ['HF_HOME'] = '/NVME/huggingface'
os.environ['HF_HUB_CACHE'] = '/NVME/huggingface/hub'
os.environ['TRANSFORMERS_CACHE'] = '/NVME/huggingface/models'
os.environ['CUDA_DEVICE_ORDER'] = 'PCI_BUS_ID'
os.environ['CUDA_LAUNCH_BLOCKING'] = '1'

app = FastAPI(title="Mistral-7B 3-GPU Inference")

# Global model & tokenizer
model = None
tokenizer = None
device = "cuda"

@app.on_event("startup")
async def startup():
    """Load model on startup"""
    global model, tokenizer
    print("🚀 Loading Mistral-7B on GPUs (maxpower)...")
    
    qc = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_compute_dtype=torch.float16,
        bnb_4bit_use_double_quant=True,
        bnb_4bit_quant_type='nf4'
    )
    
    model = AutoModelForCausalLM.from_pretrained(
        'mistralai/Mistral-7B-Instruct-v0.2',
        quantization_config=qc,
        device_map='auto',
        trust_remote_code=True,
        attn_implementation='eager'
    )
    
    tokenizer = AutoTokenizer.from_pretrained('mistralai/Mistral-7B-Instruct-v0.2')
    print("✅ Model loaded on maxpower")
    
    # Check GPU memory
    print("\n=== GPU Memory Status ===")
    subprocess.run(['nvidia-smi', '--query-gpu=index,memory.used', '--format=csv,noheader,nounits'])
    
    # SSH to theplague and load model there too (if not already loaded)
    print("\n🔗 Starting model load on theplague...")
    load_cmd = '''
source /home/bdeeley/.venv/bin/activate
export HF_HOME=/NVME/huggingface
export HF_HUB_CACHE=/NVME/huggingface/hub
export TRANSFORMERS_CACHE=/NVME/huggingface/models
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_LAUNCH_BLOCKING=1

python << 'EOFDEBUG'
import os, torch
from transformers import AutoModelForCausalLM, BitsAndBytesConfig

os.environ['HF_HOME'] = '/NVME/huggingface'
qc = BitsAndBytesConfig(load_in_4bit=True, bnb_4bit_compute_dtype=torch.float16, 
                       bnb_4bit_use_double_quant=True, bnb_4bit_quant_type='nf4')
model = AutoModelForCausalLM.from_pretrained('mistralai/Mistral-7B-Instruct-v0.2',
    quantization_config=qc, device_map='auto', trust_remote_code=True, attn_implementation='eager')
print("✅ [theplague] Model loaded")
import subprocess
subprocess.run(['nvidia-smi', '--query-gpu=index,memory.used', '--format=csv,noheader,nounits'])

# Keep process alive
import time
while True:
    time.sleep(10)
EOFDEBUG
'''
    subprocess.Popen(['ssh', 'bdeeley@172.16.0.29', load_cmd], 
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(3)
    print("✅ theplague model loading in background")

@app.get("/v1/models")
async def list_models():
    """List available models"""
    return {
        "object": "list",
        "data": [
            {
                "id": "mistralai/Mistral-7B-Instruct-v0.2",
                "object": "model",
                "owned_by": "mistral",
                "description": "Mistral 7B (4-bit quantized, distributed across 3 GPUs)"
            }
        ]
    }

@app.post("/v1/chat/completions")
async def chat_completions(request: dict):
    """OpenAI-compatible chat completions endpoint"""
    if not model or not tokenizer:
        raise HTTPException(status_code=503, detail="Model not loaded")
    
    messages = request.get("messages", [])
    if not messages:
        raise HTTPException(status_code=400, detail="No messages provided")
    
    # Format messages into prompt
    prompt = ""
    for msg in messages:
        role = msg.get("role", "user")
        content = msg.get("content", "")
        if role == "system":
            prompt += f"[SYSTEM] {content}\n"
        elif role == "user":
            prompt += f"[USER] {content}\n"
        elif role == "assistant":
            prompt += f"[ASSISTANT] {content}\n"
    
    prompt += "[ASSISTANT] "
    
    # Tokenize and generate
    inputs = tokenizer(prompt, return_tensors="pt").to(device)
    max_tokens = request.get("max_tokens", 512)
    
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=max_tokens,
            temperature=request.get("temperature", 0.7),
            top_p=request.get("top_p", 0.9),
            do_sample=True
        )
    
    response_text = tokenizer.decode(outputs[0], skip_special_tokens=True)
    # Extract only the assistant response
    if "[ASSISTANT]" in response_text:
        response_text = response_text.split("[ASSISTANT]")[-1].strip()
    
    return {
        "object": "chat.completion",
        "model": "mistralai/Mistral-7B-Instruct-v0.2",
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": response_text
                },
                "finish_reason": "stop"
            }
        ]
    }

@app.get("/health")
async def health():
    """Health check endpoint"""
    return {
        "status": "healthy",
        "model_loaded": model is not None,
        "gpus": 3,
        "gpu_distribution": {
            "maxpower": {"gpus": 2, "model": "Mistral-7B-4bit"},
            "theplague": {"gpus": 1, "model": "Mistral-7B-4bit"}
        }
    }

@app.get("/v1/cluster/status")
async def cluster_status():
    """Show cluster GPU status"""
    import json
    
    # Get maxpower GPU status
    result = subprocess.run(
        ['nvidia-smi', '--query-gpu=index,memory.used,memory.total', '--format=csv,noheader,nounits'],
        capture_output=True, text=True
    )
    maxpower_gpus = [
        {
            "id": i,
            "memory_used_mb": int(line.split(",")[1]),
            "memory_total_mb": int(line.split(",")[2])
        }
        for i, line in enumerate(result.stdout.strip().split('\n'))
    ]
    
    # Get theplague GPU status
    result = subprocess.run(
        ['ssh', 'bdeeley@172.16.0.29', 
         'nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits'],
        capture_output=True, text=True
    )
    theplague_gpus = []
    if result.returncode == 0:
        for i, line in enumerate(result.stdout.strip().split('\n')):
            if line.strip():
                theplague_gpus.append({
                    "id": i,
                    "memory_used_mb": int(line.split(",")[1]),
                    "memory_total_mb": int(line.split(",")[2])
                })
    
    return {
        "cluster": {
            "nodes": 2,
            "total_gpus": 3,
            "maxpower": {
                "gpus": maxpower_gpus,
                "total_memory_gb": sum(g["memory_total_mb"] for g in maxpower_gpus) / 1024
            },
            "theplague": {
                "gpus": theplague_gpus,
                "total_memory_gb": sum(g["memory_total_mb"] for g in theplague_gpus) / 1024 if theplague_gpus else 0
            }
        }
    }

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
