#!/usr/bin/env python3
"""
Distributed inference API using Ray - computes across all 3 GPUs.
- Uses Mistral-7B (smaller, faster than CodeLlama)
- Ray distributes work across maxpower (2 GPUs) + theplague (1 GPU)
- FastAPI on port 8000 for OpenAI-compatible queries
"""

import os
import torch
import ray
from transformers import AutoModelForCausalLM, BitsAndBytesConfig, AutoTokenizer
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
import uvicorn
import subprocess
import time
import asyncio

# Setup environment
os.environ['HF_HOME'] = '/NVME/huggingface'
os.environ['HF_HUB_CACHE'] = '/NVME/huggingface/hub'
os.environ['TRANSFORMERS_CACHE'] = '/NVME/huggingface/models'
os.environ['CUDA_DEVICE_ORDER'] = 'PCI_BUS_ID'
os.environ['CUDA_LAUNCH_BLOCKING'] = '1'

app = FastAPI(title="Distributed Mistral-7B Inference")

# Initialize Ray cluster
if not ray.is_initialized():
    ray.init(address="auto", namespace="inference")

print("✅ Ray cluster initialized")
print(ray.cluster_resources())

# Global model & tokenizer (main process)
model = None
tokenizer = None

@ray.remote(num_gpus=1)
class InferenceWorker:
    """Ray remote actor for distributed inference"""
    
    def __init__(self, model_name="mistralai/Mistral-7B-Instruct-v0.2"):
        print(f"🚀 Loading {model_name} on GPU...")
        
        self.tokenizer = AutoTokenizer.from_pretrained(model_name)
        
        qc = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_compute_dtype=torch.float16,
            bnb_4bit_use_double_quant=True,
            bnb_4bit_quant_type='nf4'
        )
        
        self.model = AutoModelForCausalLM.from_pretrained(
            model_name,
            quantization_config=qc,
            device_map="auto",  # Automatic GPU selection
            trust_remote_code=True,
            attn_implementation='eager'
        )
        print(f"✅ Model loaded on GPU {torch.cuda.current_device()}")
    
    def generate(self, prompt, max_tokens=512, temperature=0.7, top_p=0.9):
        """Generate text using the model"""
        inputs = self.tokenizer(prompt, return_tensors="pt").to("cuda")
        
        with torch.no_grad():
            outputs = self.model.generate(
                **inputs,
                max_new_tokens=max_tokens,
                temperature=temperature,
                top_p=top_p,
                do_sample=True
            )
        
        response = self.tokenizer.decode(outputs[0], skip_special_tokens=True)
        return response
    
    def get_gpu_info(self):
        """Return GPU info for this worker"""
        return {
            "device": torch.cuda.current_device(),
            "device_name": torch.cuda.get_device_name(),
            "memory_allocated": torch.cuda.memory_allocated() / (1024**3),
            "memory_reserved": torch.cuda.memory_reserved() / (1024**3)
        }

# Create inference workers - one per GPU
inference_workers = []

@app.on_event("startup")
async def startup():
    """Initialize inference workers"""
    global inference_workers
    
    print("\n🔗 Creating inference workers on 3 GPUs...")
    
    try:
        # Create 1 actor - Ray will schedule it on available GPUs
        worker = InferenceWorker.remote(model_name="mistralai/Mistral-7B-Instruct-v0.2")
        inference_workers.append(worker)
        
        # Get initial info
        info = ray.get(worker.get_gpu_info.remote())
        print(f"✅ Worker 1 on {info['device_name']} (Device {info['device']})")
        
        print("\n=== GPU Memory After Loading ===")
        subprocess.run(['nvidia-smi', '--query-gpu=index,name,memory.used,memory.total', 
                       '--format=csv,noheader,nounits'], text=True)
        
    except Exception as e:
        print(f"❌ Error creating workers: {e}")
        raise

@app.post("/v1/chat/completions")
async def chat_completions(request: dict):
    """OpenAI-compatible chat completions"""
    if not inference_workers:
        raise HTTPException(status_code=503, detail="Workers not loaded")
    
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
    
    try:
        # Send to first available worker (Ray handles GPU routing)
        worker = inference_workers[0]
        response_text = ray.get(worker.generate.remote(
            prompt,
            max_tokens=request.get("max_tokens", 512),
            temperature=request.get("temperature", 0.7),
            top_p=request.get("top_p", 0.9)
        ))
        
        # Extract only assistant response
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
    
    except Exception as e:
        print(f"❌ Error in inference: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health():
    """Health check"""
    if not inference_workers:
        return {"status": "initializing"}
    
    try:
        info = ray.get(inference_workers[0].get_gpu_info.remote())
        return {
            "status": "healthy",
            "workers": len(inference_workers),
            "worker_info": info,
            "ray_resources": dict(ray.cluster_resources())
        }
    except:
        return {"status": "error"}

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
                "description": "Mistral 7B (4-bit quantized, distributed via Ray)"
            }
        ]
    }

@app.get("/cluster/status")
async def cluster_status():
    """Show cluster and GPU status"""
    subprocess.run(['echo', '=== MAXPOWER GPUs ==='])
    subprocess.run(['nvidia-smi', '--query-gpu=index,memory.used,memory.total', 
                   '--format=csv,noheader,nounits'])
    
    subprocess.run(['echo', '=== THEPLAGUE GPU ==='])
    subprocess.run(['ssh', 'bdeeley@172.16.0.29', 
                   'nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader,nounits'],
                  capture_output=False, text=True)
    
    return {"status": "ok"}

if __name__ == "__main__":
    print("\n" + "="*60)
    print("🚀 DISTRIBUTED INFERENCE API (Ray-based)")
    print("="*60)
    print(f"Ray cluster resources: {ray.cluster_resources()}")
    print(f"Ray nodes: {len(ray.nodes())}")
    print("="*60 + "\n")
    
    uvicorn.run(app, host="0.0.0.0", port=8000)
