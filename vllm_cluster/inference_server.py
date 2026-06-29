#!/usr/bin/env python3
"""
Simple local inference server using transformers + FastAPI
Loads TinyLlama-1.1B on single GPU and exposes OpenAI-compatible API
"""

import torch
import os
from fastapi import FastAPI, HTTPException
import uvicorn
from transformers import AutoTokenizer, AutoModelForCausalLM
from datetime import datetime
from typing import Optional

# Configure environment
os.environ["HF_HOME"] = os.environ.get("HF_HOME", "/NVME/huggingface")
os.environ["FLASH_ATTENTION_2"] = "0"

# Create app
app = FastAPI()

# Model configuration
MODEL_NAME = "codellama/CodeLlama-34b-Instruct-hf"  # 34B model (~20GB), spans both GPUs
MAX_TOKEN_LENGTH = 2048

print("=" * 60)
print("🚀 Local Multi-GPU Inference Server")
print("=" * 60)
print(f"Model:  {MODEL_NAME}")
print(f"Device: device_map='auto' (ALL GPUs: RTX 3060 12GB + Quadro P6000 24GB)")
print(f"Total VRAM: 36GB available")
print()

# Load model and tokenizer
print("Loading model and tokenizer...")
try:
    tokenizer = AutoTokenizer.from_pretrained(MODEL_NAME, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_NAME,
        torch_dtype=torch.float16,
        device_map="auto",  # Automatically distribute across ALL available GPUs
        attn_implementation="eager",
        trust_remote_code=True,
    )
    model.eval()
    
    # Disable FlashAttention if config supports it
    if hasattr(model.config, "_flash_attn_2_enabled"):
        model.config._flash_attn_2_enabled = False
    
    print("✅ Model loaded successfully (Ampere GPU only)")
    print()
except Exception as e:
    print(f"❌ Failed to load model: {e}")
    import traceback
    traceback.print_exc()
    exit(1)


@app.get("/health")
def health_check():
    """Health check endpoint"""
    return {"status": "ok", "timestamp": datetime.now().isoformat()}


@app.get("/v1/models")
def list_models():
    """List available models"""
    return {
        "object": "list",
        "data": [
            {
                "id": MODEL_NAME,
                "object": "model",
                "owned_by": "local",
                "permission": []
            }
        ]
    }


@app.post("/v1/chat/completions")
def chat_completions(request: dict):
    """OpenAI-compatible chat completions endpoint"""
    try:
        messages = request.get("messages", [])
        max_tokens = request.get("max_tokens", 256)
        temperature = request.get("temperature", 0.7)
        
        if not messages:
            raise HTTPException(status_code=400, detail="No messages provided")
        
        # Format prompt for Mistral
        prompt_text = ""
        for msg in messages:
            role = msg.get("role", "user")
            content = msg.get("content", "")
            if role == "user":
                prompt_text += f"[INST] {content} [/INST]"
            else:
                prompt_text += f" {content}"
        
        # Tokenize
        inputs = tokenizer(prompt_text, return_tensors="pt").to(model.device)
        
        # Generate
        with torch.no_grad():
            outputs = model.generate(
                **inputs,
                max_new_tokens=max_tokens,
                temperature=temperature if temperature != 0 else 1.0,
                top_p=0.9 if temperature != 0 else 1.0,
                do_sample=temperature != 0,
            )
        
        # Decode
        generated_text = tokenizer.decode(outputs[0], skip_special_tokens=True)
        response_text = generated_text[len(prompt_text):].strip()
        
        return {
            "id": "chatcmpl-local",
            "object": "chat.completion",
            "created": datetime.now().timestamp(),
            "model": MODEL_NAME,
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
        
    except HTTPException:
        raise
    except Exception as e:
        print(f"❌ Error in /v1/chat/completions: {e}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))


if __name__ == "__main__":
    print("=" * 60)
    print("✅ Server ready!")
    print("=" * 60)
    print()
    print("Testing endpoints:")
    print("  Health:  curl http://localhost:8000/health")
    print("  Models:  curl http://localhost:8000/v1/models")
    print("  Chat:    curl -X POST http://localhost:8000/v1/chat/completions \\")
    print('           -H "Content-Type: application/json" \\')
    print('           -d \'{"messages":[{"role":"user","content":"Hello"}],"max_tokens":100}\'')
    print()
    print("Starting uvicorn...")
    print()
    
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")
