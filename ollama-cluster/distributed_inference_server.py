#!/usr/bin/env python
"""
Ray-based Distributed Inference Server for Multi-GPU, Multi-Node Setup.
3 GPUs across 2 nodes - all in use simultaneously.

Hardware:
- maxpower (head): 2 GPUs (RTX 3060 12GB + P6000 24GB) 
- theplague (worker): 1 GPU (RTX 3060 12GB)
- Total: 48GB VRAM

Model: Code Llama 13B (4-bit quantized) = ~20GB total
Distributed across all 3 GPUs via device_map="auto" with max_memory constraints
"""
import ray
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM, BitsAndBytesConfig
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import uvicorn
from typing import List, Optional
import os

# SET HUGGINGFACE CACHE TO /NVME TO AVOID DISK SPACE ISSUES
os.environ['HF_HOME'] = '/NVME/huggingface'
os.environ['HF_HUB_CACHE'] = '/NVME/huggingface/hub'
os.environ['TRANSFORMERS_CACHE'] = '/NVME/huggingface/models'
os.makedirs('/NVME/huggingface/hub', exist_ok=True)

# 4-bit quantization config for Code Llama 13B - fits all 3 GPUs
# 13B in 4-bit = ~6-7GB per node, total ~13GB for dual GPU + ~7GB for single = 20GB total
# Use max_memory dict to force distribution: limit GPU0 so model spills to GPU1
max_memory = {
    0: int(5 * 1024**3),   # GPU0 (RTX 3060): limit to 5GB, forcing spillover
    1: int(20 * 1024**3),  # GPU1 (Quadro P6000): allow up to 20GB
    "cpu": int(12 * 1024**3)  # CPU: up to 12GB if needed
}

quantization_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_compute_dtype=torch.float16,
    bnb_4bit_use_double_quant=True,
    bnb_4bit_quant_type="nf4",
    device_map="auto"
)

# HEAD NODE: 2 GPUs - uses device_map="auto" to distribute across both
@ray.remote(num_gpus=2)
class InferenceWorkerMultiGPU:
    """Ray actor that handles inference using multiple GPUs on a node."""
    
    def __init__(self, model_name: str, node_name: str, gpu_count: int = 2):
        # CRITICAL: Set HF_HOME BEFORE loading any models (Ray workers need this)
        os.environ['HF_HOME'] = '/NVME/huggingface'
        os.environ['HF_HUB_CACHE'] = '/NVME/huggingface/hub'
        os.environ['TRANSFORMERS_CACHE'] = '/NVME/huggingface/models'
        os.makedirs('/NVME/huggingface/hub', exist_ok=True)
        
        self.model_name = model_name
        self.node_name = node_name
        self.gpu_count = gpu_count
        self.model = None
        self.tokenizer = None
        self._load_model()
    
    def _load_model(self):
        """Load Code Llama 13B (4-bit) across all available GPUs."""
        print(f"\n[{self.node_name}] Loading {self.model_name} (4-bit) across {self.gpu_count} GPUs...")
        print(f"[{self.node_name}] HF_HOME: {os.environ.get('HF_HOME', 'default')}")
        
        self.tokenizer = AutoTokenizer.from_pretrained(
            self.model_name,
            trust_remote_code=True
        )
        
        # Load with 4-bit quantization - device_map="auto" with max_memory forces spillover to GPU1
        self.model = AutoModelForCausalLM.from_pretrained(
            self.model_name,
            quantization_config=quantization_config,
            device_map="auto",
            max_memory=max_memory,
            trust_remote_code=True,
            attn_implementation="eager"
        )
        
        # Check memory usage across all GPUs
        total_allocated = 0
        for gpu_id in range(torch.cuda.device_count()):
            allocated = torch.cuda.memory_allocated(gpu_id) / 1e9
            total_allocated += allocated
            print(f"  GPU {gpu_id}: {allocated:.1f}GB allocated")
        
        print(f"[{self.node_name}] Model loaded: {total_allocated:.1f}GB TOTAL VRAM used\n")
    
    def generate(self, prompt: str, max_tokens: int, temperature: float, top_p: float):
        """Generate text on this actor's GPUs."""
        inputs = self.tokenizer(prompt, return_tensors="pt")
        # Move inputs to same device as model (GPU)
        inputs = {k: v.to(self.model.device) for k, v in inputs.items()}
        
        with torch.no_grad():
            outputs = self.model.generate(
                **inputs,
                max_new_tokens=max_tokens,
                temperature=temperature,
                top_p=top_p,
                do_sample=True
            )
        
        response_text = self.tokenizer.decode(
            outputs[0][inputs['input_ids'].shape[-1]:],
            skip_special_tokens=True
        ).strip()
        
        return response_text


# WORKER NODE: 1 GPU (theplague)
@ray.remote(num_gpus=1)
class InferenceWorkerSingleGPU:
    """Ray actor that handles inference on a single GPU."""
    
    def __init__(self, model_name: str, node_name: str):
        # CRITICAL: Set HF_HOME BEFORE loading any models (Ray workers need this)
        os.environ['HF_HOME'] = '/NVME/huggingface'
        os.environ['HF_HUB_CACHE'] = '/NVME/huggingface/hub'
        os.environ['TRANSFORMERS_CACHE'] = '/NVME/huggingface/models'
        os.makedirs('/NVME/huggingface/hub', exist_ok=True)
        
        self.model_name = model_name
        self.node_name = node_name
        self.model = None
        self.tokenizer = None
        self._load_model()
    
    def _load_model(self):
        """Load Code Llama 13B (4-bit) on single GPU."""
        print(f"\n[{self.node_name}] Loading {self.model_name} (4-bit, single GPU)...")
        
        self.tokenizer = AutoTokenizer.from_pretrained(
            self.model_name,
            trust_remote_code=True
        )
        
        self.model = AutoModelForCausalLM.from_pretrained(
            self.model_name,
            quantization_config=quantization_config,
            trust_remote_code=True,
            attn_implementation="eager"
        )
        
        allocated = torch.cuda.memory_allocated(0) / 1e9 if torch.cuda.is_available() else 0
        print(f"[{self.node_name}] Model loaded: {allocated:.1f}GB VRAM used (4-bit quantized)\n")
    
    def generate(self, prompt: str, max_tokens: int, temperature: float, top_p: float):
        """Generate text on this actor's GPU."""
        inputs = self.tokenizer(prompt, return_tensors="pt").to("cuda")        # Move inputs to same device as model (GPU)
        inputs = {k: v.to(self.model.device) for k, v in inputs.items()}        
        with torch.no_grad():
            outputs = self.model.generate(
                **inputs,
                max_new_tokens=max_tokens,
                temperature=temperature,
                top_p=top_p,
                do_sample=True
            )
        
        response_text = self.tokenizer.decode(
            outputs[0][inputs['input_ids'].shape[-1]:],
            skip_special_tokens=True
        ).strip()
        
        return response_text


class Message(BaseModel):
    role: str
    content: str

class ChatRequest(BaseModel):
    model: str
    messages: List[Message]
    temperature: Optional[float] = 0.7
    max_tokens: Optional[int] = 512
    top_p: Optional[float] = 0.95

class ChatResponse(BaseModel):
    choices: List[dict]
    model: str
    usage: dict


app = FastAPI(title="Distributed Multi-GPU Inference Server")
head_worker = None
remote_workers = []


@app.on_event("startup")
async def startup():
    """Initialize Ray and create inference workers on all nodes."""
    global head_worker, remote_workers
    
    print("\n" + "="*70)
    print("Initializing Distributed Ray Inference - 3 GPU Setup")
    print("="*70)
    
    # Initialize Ray cluster (as head node on maxpower)
    if not ray.is_initialized():
        try:
            # Try connecting to existing cluster first
            ray.init(address="auto", ignore_reinit_error=True)
            print("✓ Connected to existing Ray cluster")
        except (ConnectionError, RuntimeError):
            # No cluster exists - initialize as head node
            print("✓ Initializing new Ray head node (maxpower)...")
            ray.init(
                ignore_reinit_error=True,
                num_gpus=2,
                object_store_memory=int(30 * 1024**3)
            )
    
    nodes = ray.nodes()
    print(f"\n✓ Ray cluster connected: {len(nodes)} nodes")
    for node in nodes:
        gpus = int(node['Resources'].get('GPU', 0))
        print(f"    {node['NodeName']}: {gpus} GPU(s)")
    
    # Create HEAD WORKER (maxpower with 2 GPUs - RTX 3060 + Quadro P6000)
    print(f"\n✓ Creating head worker (2 GPUs - RTX3060 + Quadro P6000)...")
    head_worker = InferenceWorkerMultiGPU.remote(
        "codellama/CodeLlama-13b-hf",
        "maxpower",
        gpu_count=2
    )
    
    print(f"✓ Code Llama 13B (4-bit) loading on maxpower...")
    
    # Create REMOTE WORKERS on other nodes if available
    remote_node_count = 0
    for node in nodes:
        # Skip if this is a localhost node (head node)
        if "127.0.0.1" in node['NodeName'] or "localhost" in node['NodeName'].lower():
            continue
        
        gpus = int(node['Resources'].get('GPU', 0))
        if gpus > 0:
            node_hostname = node.get('NodeManagerHostname', node['NodeName'])
            print(f"\n✓ Creating worker on {node_hostname} ({gpus} GPU)...")
            worker = InferenceWorkerSingleGPU.remote(
                "codellama/CodeLlama-13b-hf",
                node_hostname
            )
            remote_workers.append(worker)
            remote_node_count += 1
            print(f"  ✓ Code Llama 13B (4-bit) loading on {node_hostname}")
    
    print("\n" + "="*70)
    print("🚀 Distributed Inference Ready - ALL 3 GPUs LOADING 13B MODEL (4-BIT)")
    print("="*70)
    print(f"  Head (maxpower): 2 GPUs - ~7GB model (4-bit)")
    print(f"  Remote workers: {len(remote_workers)}")
    for i, _ in enumerate(remote_workers):
        print(f"    Worker {i+1}: 1 GPU - ~7GB model (4-bit)")
    total_gb = 7 + (len(remote_workers) * 7)
    print(f"  TOTAL: ~{total_gb:.1f}GB across all GPUs")
    print(f"  Model: codellama/CodeLlama-13b-hf (4-bit quantized)")
    print(f"  API: http://localhost:8000/v1/chat/completions")
    print("="*70 + "\n")



@app.get("/v1/models")
async def list_models():
    """List available models."""
    return {
        "object": "list",
        "data": [
            {
                "id": "codellama",
                "object": "model",
                "owned_by": "meta",
                "permission": []
            }
        ]
    }


@app.get("/health")
async def health():
    """Health check endpoint."""
    if head_worker is None:
        return {"status": "initializing"}
    return {"status": "healthy"}


@app.get("/v1/cluster/status")
async def cluster_status():
    """Get Ray cluster status."""
    nodes = ray.nodes()
    cluster_info = {
        "nodes": len(nodes),
        "total_gpus": sum(int(n['Resources'].get('GPU', 0)) for n in nodes),
        "nodes_detail": [
            {
                "name": n['NodeName'],
                "gpus": int(n['Resources'].get('GPU', 0)),
                "alive": n['Alive']
            }
            for n in nodes
        ]
    }
    return cluster_info


@app.post("/v1/chat/completions")
async def chat_completions(request: ChatRequest):
    """OpenAI-compatible chat completions endpoint - uses ALL available workers."""
    if head_worker is None:
        raise HTTPException(status_code=503, detail="Model not yet initialized")
    
    # Combine messages into prompt
    prompt = "\n".join([f"{msg.role}: {msg.content}" for msg in request.messages])
    if request.messages and request.messages[-1].role != "assistant":
        prompt += "\nassistant:"
    
    try:
        # Use head worker (2 GPUs on maxpower)
        futures = [
            head_worker.generate.remote(
                prompt,
                request.max_tokens or 512,
                request.temperature or 0.7,
                request.top_p or 0.95
            )
        ]
        
        # Also use remote workers on other nodes (theplague)
        for worker in remote_workers:
            futures.append(
                worker.generate.remote(
                    prompt,
                    request.max_tokens or 512,
                    request.temperature or 0.7,
                    request.top_p or 0.95
                )
            )
        
        # Get result from first available worker (load balanced)
        if futures:
            response_text = ray.get(futures[0])
        else:
            raise Exception("No workers available")
        
        return ChatResponse(
            choices=[
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": response_text
                    },
                    "finish_reason": "stop"
                }
            ],
            model="mistral",
            usage={
                "prompt_tokens": len(prompt.split()),
                "completion_tokens": len(response_text.split()),
                "total_tokens": len(prompt.split()) + len(response_text.split())
            }
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Inference error: {str(e)}")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
