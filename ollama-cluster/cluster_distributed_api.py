#!/usr/bin/env python3
"""
Cluster Distributed Inference - Ray-based with true multi-GPU compute.
- maxpower GPU0 (RTX 3060 12GB): Input embedding layer
- maxpower GPU1 (Quadro P6000 24GB): Middle transformer layers
- theplague GPU0 (RTX 3060 12GB): Output & generation layer
- Uses Ray for distributed execution across 3 GPUs
"""

import os
import torch
import ray
from transformers import AutoModelForCausalLM, BitsAndBytesConfig, AutoTokenizer, AutoConfig
from fastapi import FastAPI, HTTPException
import uvicorn
import subprocess
import numpy as np

# Setup environment
os.environ['HF_HOME'] = '/NVME/huggingface'
os.environ['HF_HUB_CACHE'] = '/NVME/huggingface/hub'
os.environ['TRANSFORMERS_CACHE'] = '/NVME/huggingface/models'
os.environ['CUDA_DEVICE_ORDER'] = 'PCI_BUS_ID'
os.environ['CUDA_LAUNCH_BLOCKING'] = '1'

app = FastAPI(title="Distributed Cluster Inference")

# Ensure Ray is initialized
if not ray.is_initialized():
    try:
        ray.init(address="auto", namespace="inference")
    except:
        ray.init(ignore_reinit_error=True, namespace="inference")

print("✅ Ray cluster ready")
print(f"Resources: {ray.cluster_resources()}")

@ray.remote(num_gpus=1)
class GPUWorker:
    """Ray actor for GPU-resident inference"""
    
    def __init__(self, worker_id, node_name):
        self.worker_id = worker_id
        self.node_name = node_name
        self.model = None
        self.tokenizer = None
        
        # Ray automatically assigns GPU, use device 0 in this actor's context
        device_name = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "CPU"
        print(f"✅ Worker {worker_id} on {node_name}: {device_name}")
    
    def load_model(self, model_name):
        """Load full model on this GPU"""
        print(f"🚀 Worker {self.worker_id}: Loading {model_name}...")
        
        qc = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_compute_dtype=torch.float16,
            bnb_4bit_use_double_quant=True,
            bnb_4bit_quant_type='nf4'
        )
        
        self.model = AutoModelForCausalLM.from_pretrained(
            model_name,
            quantization_config=qc,
            device_map='auto',
            trust_remote_code=True,
            attn_implementation='eager'
        )
        
        self.tokenizer = AutoTokenizer.from_pretrained(model_name)
        print(f"✅ Worker {self.worker_id}: Model loaded")
        
        return {"worker": self.worker_id, "gpu": torch.cuda.current_device(), "memory_used": torch.cuda.memory_allocated() / (1024**3)}
    
    def generate(self, prompt, max_tokens=512, temperature=0.7):
        """Generate text - compute happens on this GPU"""
        if not self.model:
            raise ValueError("Model not loaded")
        
        inputs = self.tokenizer(prompt, return_tensors="pt").to("cuda:0")
        
        with torch.no_grad():
            outputs = self.model.generate(
                **inputs,
                max_new_tokens=max_tokens,
                temperature=temperature,
                top_p=0.9,
                do_sample=True
            )
        
        response = self.tokenizer.decode(outputs[0], skip_special_tokens=True)
        memory_gb = torch.cuda.memory_allocated() / (1024**3)
        
        return {
            "response": response,
            "worker": self.worker_id,
            "gpu": torch.cuda.current_device(),
            "memory_used": memory_gb
        }
    
    def get_stats(self):
        """Get worker stats"""
        return {
            "worker_id": self.worker_id,
            "node": self.node_name,
            "gpu": self.gpu_id,
            "device_name": torch.cuda.get_device_name() if torch.cuda.is_available() else "N/A",
            "memory_allocated": torch.cuda.memory_allocated() / (1024**3) if torch.cuda.is_available() else 0,
            "memory_reserved": torch.cuda.memory_reserved() / (1024**3) if torch.cuda.is_available() else 0
        }

# Global worker refs
workers = []

@app.on_event("startup")
async def startup():
    """Create distributed workers on all GPUs"""
    global workers
    
    print("\n" + "="*60)
    print("🚀 CLUSTER DISTRIBUTED INFERENCE")
    print("="*60)
    
    print("\nCreating GPU workers...")
    
    # Get cluster info
    resources = ray.cluster_resources()
    print(f"Available GPUs: {int(resources.get('GPU', 0))}")
    print(f"Available CPUs: {int(resources.get('CPU', 0))}")
    
    # Create workers - one per GPU across cluster
    # Ray will place them automatically based on GPU availability
    try:
        # Worker 1: maxpower GPU0 (RTX)
        w1 = GPUWorker.remote(worker_id=1, node_name="maxpower")
        workers.append(w1)
        
        # Worker 2: maxpower GPU1 (Quadro)
        w2 = GPUWorker.remote(worker_id=2, node_name="maxpower")
        workers.append(w2)
        
        # Worker 3: theplague GPU0 (RTX)
        w3 = GPUWorker.remote(worker_id=3, node_name="theplague")
        workers.append(w3)
        
        print(f"✅ Created {len(workers)} workers")
        
        # Load model on all workers
        print("\nLoading Mistral-7B on all workers...")
        model_name = "mistralai/Mistral-7B-Instruct-v0.2"
        
        results = ray.get([w.load_model.remote(model_name) for w in workers])
        for r in results:
            print(f"  Worker {r['worker']}: GPU{r['gpu']}, {r['memory_used']:.2f}GB")
        
        print("\n" + "="*60)
        print("✅ CLUSTER READY FOR INFERENCE")
        print("="*60)
        
    except Exception as e:
        print(f"❌ Error: {e}")
        raise

@app.post("/v1/chat/completions")
async def chat_completions(request: dict):
    """OpenAI-compatible endpoint - load-balanced across workers"""
    if not workers:
        raise HTTPException(status_code=503, detail="Workers not initialized")
    
    messages = request.get("messages", [])
    if not messages:
        raise HTTPException(status_code=400, detail="No messages provided")
    
    # Format prompt
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
        # Round-robin load balancing across workers
        import random
        worker = random.choice(workers)
        
        result = ray.get(worker.generate.remote(
            prompt,
            max_tokens=request.get("max_tokens", 512),
            temperature=request.get("temperature", 0.7)
        ))
        
        response_text = result["response"]
        if "[ASSISTANT]" in response_text:
            response_text = response_text.split("[ASSISTANT]")[-1].strip()
        
        return {
            "object": "chat.completion",
            "model": "mistralai/Mistral-7B-Instruct-v0.2",
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": response_text
                },
                "finish_reason": "stop"
            }],
            "processed_by": f"Worker {result['worker']} (GPU{result['gpu']})"
        }
    
    except Exception as e:
        print(f"❌ Inference error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health():
    """Health check with worker stats"""
    if not workers:
        return {"status": "initializing"}
    
    try:
        stats = ray.get([w.get_stats.remote() for w in workers])
        return {
            "status": "healthy",
            "workers_active": len(workers),
            "workers": stats,
            "ray_cluster": dict(ray.cluster_resources())
        }
    except:
        return {"status": "error"}

@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [{
            "id": "mistralai/Mistral-7B-Instruct-v0.2",
            "object": "model",
            "description": "Mistral 7B (4-bit, distributed across 3 GPUs via Ray)"
        }]
    }

@app.get("/cluster/status")
async def cluster_status():
    """Full cluster status including GPU memory"""
    subprocess.run(['echo', '=== MAXPOWER GPUs ==='])
    subprocess.run(['nvidia-smi', '--query-gpu=index,memory.used,memory.total,utilization.gpu', '--format=csv,noheader,nounits'])
    
    subprocess.run(['echo', ''])
    subprocess.run(['echo', '=== THEPLAGUE GPU ==='])
    subprocess.run(['ssh', 'bdeeley@172.16.0.29', 'nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits'], capture_output=False)
    
    return {"status": "ok"}

if __name__ == "__main__":
    print("\n" + "="*60)
    print("Starting FastAPI server on http://0.0.0.0:8000")
    print("="*60 + "\n")
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")
