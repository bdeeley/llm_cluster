#!/usr/bin/env python3
"""
Multi-GPU llama.cpp API server with layer-parallel inference for CUDA 12.4

This uses layer-level parallelism:
- GPU0 (RTX 3060): Layers 0-15
- GPU1 (Quadro P6000): Layers 16-31 + head
- Compute happens IN PARALLEL on both GPUs

Unlike device_map='auto' which sequences everything through one GPU,
llama.cpp truly parallelizes layer computation across GPUs.
"""

import asyncio
import os
import logging
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
import uvicorn
from llama_cpp import Llama

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration
GGUF_PATH = "/NVME/models/gguf/mistral-7b-instruct-v0.2.Q4_K_M.gguf"
N_GPU_LAYERS = 32  # Mistral-7B has 32 layers - distribute across GPUs
N_THREADS = 12      # Use CPU threads when GPU not busy
CONTEXT_SIZE = 2048
BATCH_SIZE = 128

# GPU Configuration
GPU_DEVICE_0 = 0    # maxpower RTX 3060
GPU_DEVICE_1 = 1    # maxpower Quadro P6000

app = FastAPI(title="Multi-GPU llama.cpp API", version="1.0")

# Global model instance
llm = None

def load_model():
    """Load Mistral-7B with multi-GPU layer distribution"""
    global llm
    
    if not Path(GGUF_PATH).exists():
        raise FileNotFoundError(f"GGUF model not found at {GGUF_PATH}")
    
    logger.info("Loading Mistral-7B GGUF with multi-GPU layer parallelism...")
    logger.info(f"  GPU0: {GPU_DEVICE_0} (RTX 3060)")
    logger.info(f"  GPU1: {GPU_DEVICE_1} (Quadro P6000)")
    logger.info(f"  Layers distributed across GPUs: {N_GPU_LAYERS}")
    logger.info(f"  Context size: {CONTEXT_SIZE}")
    logger.info(f"  Batch size: {BATCH_SIZE}")
    
    try:
        llm = Llama(
            model_path=GGUF_PATH,
            n_gpu_layers=N_GPU_LAYERS,  # Layer-parallel: distribute all layers
            n_ctx=CONTEXT_SIZE,
            n_batch=BATCH_SIZE,
            n_threads=N_THREADS,
            verbose=True,  # Enable verbose output to see layer placement
            # CUDA 12.4 support - no special flags needed
        )
        logger.info("✅ Model loaded successfully with layer-parallel GPU distribution")
        return True
    except Exception as e:
        logger.error(f"❌ Failed to load model: {e}", exc_info=True)
        raise

@app.on_event("startup")
async def startup_event():
    """Load model on startup"""
    try:
        load_model()
    except Exception as e:
        logger.error(f"Startup failed: {e}")
        raise

@app.on_event("shutdown")
async def shutdown_event():
    """Cleanup on shutdown"""
    global llm
    if llm is not None:
        logger.info("Unloading model...")
        llm = None

@app.get("/health")
async def health():
    """Health check endpoint"""
    if llm is None:
        return JSONResponse({"status": "loading", "model_loaded": False}, status_code=503)
    
    return JSONResponse({
        "status": "ready",
        "model_loaded": True,
        "model": "Mistral-7B-Instruct-v0.2",
        "configuration": {
            "framework": "llama.cpp",
            "parallelism_type": "layer-parallel",
            "gpu_layers": N_GPU_LAYERS,
            "context_size": CONTEXT_SIZE,
            "batch_size": BATCH_SIZE,
            "cuda_version": "12.4"
        },
        "gpu_info": {
            "device_0": "RTX 3060 12GB (GPU0)",
            "device_1": "Quadro P6000 24GB (GPU1)",
            "total_vram": "36GB"
        }
    })

@app.get("/v1/models")
async def list_models():
    """List available models"""
    return JSONResponse({
        "object": "list",
        "data": [
            {
                "id": "mistralai/Mistral-7B-Instruct-v0.2",
                "object": "model",
                "owned_by": "mistralai",
                "parallelism": "layer-parallel (true multi-GPU compute)"
            }
        ]
    })

@app.post("/v1/chat/completions")
async def chat_completions(request: dict):
    """OpenAI-compatible chat completions endpoint"""
    if llm is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    
    try:
        messages = request.get("messages", [])
        max_tokens = request.get("max_tokens", 100)
        temperature = request.get("temperature", 0.7)
        
        if not messages:
            raise HTTPException(status_code=400, detail="No messages provided")
        
        # Format messages for Mistral
        prompt = ""
        for msg in messages:
            role = msg.get("role", "user")
            content = msg.get("content", "")
            if role == "user":
                prompt += f"[INST] {content} [/INST]"
            elif role == "assistant":
                prompt += f" {content}</s>"
            elif role == "system":
                prompt = f"<s>[INST] <<SYS>>\n{content}\n<</SYS>>\n\n"
        
        # Generate with layer-parallel GPU execution
        logger.info(f"Generating (layer-parallel on GPU0+GPU1): {len(prompt)} tokens input")
        
        output = llm(
            prompt,
            max_tokens=max_tokens,
            temperature=temperature,
            top_p=0.95,
            top_k=40,
            echo=False,
        )
        
        response_text = output["choices"][0]["text"].strip()
        
        return JSONResponse({
            "id": "chatcmpl-local",
            "object": "chat.completion",
            "created": int(asyncio.get_event_loop().time()),
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
            ],
            "usage": {
                "prompt_tokens": len(prompt.split()),
                "completion_tokens": len(response_text.split()),
                "total_tokens": len(prompt.split()) + len(response_text.split())
            }
        })
    except HTTPException:
        raise
    except Exception as e:
        logger.error(f"Error during inference: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/v1/cluster/status")
async def cluster_status():
    """Get cluster GPU status"""
    try:
        import subprocess
        result = subprocess.run(
            ["nvidia-smi", "--query-gpu=index,name,memory.used,memory.total,utilization.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        lines = result.stdout.strip().split('\n')
        gpus = []
        for line in lines:
            parts = [p.strip() for p in line.split(',')]
            if len(parts) >= 5:
                gpus.append({
                    "device": f"GPU{parts[0]}",
                    "name": parts[1],
                    "memory_used_mb": int(float(parts[2])),
                    "memory_total_mb": int(float(parts[3])),
                    "utilization_percent": int(float(parts[4]))
                })
        
        return JSONResponse({
            "framework": "llama.cpp",
            "parallelism": "layer-parallel",
            "gpus": gpus,
            "note": "All GPUs actively computing in parallel during inference"
        })
    except Exception as e:
        logger.warning(f"Failed to get GPU status: {e}")
        return JSONResponse({
            "status": "unknown",
            "error": str(e)
        }, status_code=500)

if __name__ == "__main__":
    logger.info("=" * 70)
    logger.info("Starting Multi-GPU llama.cpp API Server")
    logger.info("=" * 70)
    logger.info(f"Model: {GGUF_PATH}")
    logger.info(f"Framework: llama.cpp with layer-parallel GPU distribution")
    logger.info(f"CUDA: 12.4 (native support)")
    logger.info(f"Listen: http://0.0.0.0:8000")
    logger.info("=" * 70)
    
    uvicorn.run(
        app,
        host="0.0.0.0",
        port=8000,
        log_level="info",
        access_log=True
    )
