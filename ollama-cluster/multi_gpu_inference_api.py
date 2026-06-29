#!/usr/bin/env python3
"""
Multi-GPU inference using torch.nn.parallel.DataParallel for distributed compute.
- Forces computation across both maxpower GPUs
- FastAPI on port 8000
"""

import os
import torch
import torch.nn.parallel
from transformers import AutoModelForCausalLM, BitsAndBytesConfig, AutoTokenizer
from fastapi import FastAPI, HTTPException
import uvicorn
import subprocess

# Setup environment
os.environ['HF_HOME'] = '/NVME/huggingface'
os.environ['HF_HUB_CACHE'] = '/NVME/huggingface/hub'
os.environ['TRANSFORMERS_CACHE'] = '/NVME/huggingface/models'
os.environ['CUDA_DEVICE_ORDER'] = 'PCI_BUS_ID'
os.environ['CUDA_LAUNCH_BLOCKING'] = '1'

app = FastAPI(title="Multi-GPU Mistral-7B Inference")

model = None
tokenizer = None

@app.on_event("startup")
async def startup():
    """Load model with DataParallel for multi-GPU compute"""
    global model, tokenizer
    print("🚀 Loading Mistral-7B with DataParallel (both GPUs)...")
    
    qc = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_compute_dtype=torch.float16,
        bnb_4bit_use_double_quant=True,
        bnb_4bit_quant_type='nf4'
    )
    
    # Load model on GPU:0 first
    model = AutoModelForCausalLM.from_pretrained(
        'mistralai/Mistral-7B-Instruct-v0.2',
        quantization_config=qc,
        device_map="cuda:0",  # Primary device
        trust_remote_code=True,
        attn_implementation='eager'
    )
    
    # Wrap with DataParallel to use both GPUs for compute
    if torch.cuda.device_count() > 1:
        print(f"✅ Wrapping model with DataParallel for {torch.cuda.device_count()} GPUs")
        model = torch.nn.parallel.DataParallel(model, device_ids=[0, 1])
    
    tokenizer = AutoTokenizer.from_pretrained('mistralai/Mistral-7B-Instruct-v0.2')
    
    print("✅ Model ready on GPUs")
    subprocess.run(['nvidia-smi', '--query-gpu=index,memory.used', '--format=csv,noheader,nounits'])

@app.post("/v1/chat/completions")
async def chat_completions(request: dict):
    """OpenAI-compatible chat completions"""
    if not model:
        raise HTTPException(status_code=503, detail="Model not loaded")
    
    messages = request.get("messages", [])
    if not messages:
        raise HTTPException(status_code=400, detail="No messages provided")
    
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
    
    try:
        inputs = tokenizer(prompt, return_tensors="pt").to("cuda:0")
        
        with torch.no_grad():
            outputs = model.generate(
                **inputs,
                max_new_tokens=request.get("max_tokens", 512),
                temperature=request.get("temperature", 0.7),
                top_p=request.get("top_p", 0.9),
                do_sample=True
            )
        
        response_text = tokenizer.decode(outputs[0], skip_special_tokens=True)
        if "[ASSISTANT]" in response_text:
            response_text = response_text.split("[ASSISTANT]")[-1].strip()
        
        return {
            "object": "chat.completion",
            "model": "mistralai/Mistral-7B-Instruct-v0.2",
            "choices": [{"index": 0, "message": {"role": "assistant", "content": response_text}, "finish_reason": "stop"}]
        }
    except Exception as e:
        print(f"Error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health():
    return {"status": "healthy", "model": "mistral-7b", "gpus": torch.cuda.device_count()}

@app.get("/v1/models")
async def list_models():
    return {"object": "list", "data": [{"id": "mistralai/Mistral-7B-Instruct-v0.2", "object": "model"}]}

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
