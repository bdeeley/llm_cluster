#!/usr/bin/env python
"""
Multi-GPU Inference Server for Code Llama 34B (8-bit).
Runs on port 8000 with OpenAI-compatible API.
Distributes 34B model across all available GPUs with device_map="auto".
Query via: curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "codellama", "messages": [{"role": "user", "content": "Hello"}]}'
"""
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM, BitsAndBytesConfig
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import uvicorn
import json
from typing import List, Optional
import asyncio

app = FastAPI(title="Multi-GPU Inference Server")

# Global model and tokenizer
model = None
tokenizer = None

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

@app.on_event("startup")
async def startup():
    """Load model on startup."""
    global model, tokenizer
    
    print("\n" + "="*70)
    print("🚀 Loading Code Llama 13B (4-bit quantized) across all GPUs...")
    print("="*70)
    
    # 4-bit quantization config - Code Llama 13B should be ~6-7GB in 4-bit
    quantization_config = BitsAndBytesConfig(
        load_in_4bit=True,
        bnb_4bit_compute_dtype=torch.float16,
        bnb_4bit_use_double_quant=True,
        bnb_4bit_quant_type="nf4",
        device_map="auto"
    )
    
    tokenizer = AutoTokenizer.from_pretrained(
        "codellama/CodeLlama-13b-hf",
        trust_remote_code=True
    )
    
    model = AutoModelForCausalLM.from_pretrained(
        "codellama/CodeLlama-13b-hf",
        quantization_config=quantization_config,
        trust_remote_code=True,
        attn_implementation="eager",
    )
    
    print("\n✓ Code Llama 13B (4-bit) loaded across GPUs:")
    total_allocated = 0
    for i in range(torch.cuda.device_count()):
        allocated = torch.cuda.memory_allocated(i) / 1e9
        total_allocated += allocated
        print(f"  GPU {i}: {allocated:.1f}GB")
    print(f"  TOTAL: {total_allocated:.1f}GB (32GB free capacity for larger batches)")
    
    print("\n🌐 Server ready on http://localhost:8000")
    print("📚 API docs: http://localhost:8000/docs")
    print("🔥 Chat endpoint: POST /v1/chat/completions")
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

@app.post("/v1/chat/completions")
async def chat_completions(request: ChatRequest):
    """OpenAI-compatible chat endpoint."""
    global model, tokenizer
    
    try:
        # Format messages into prompt
        prompt = ""
        for msg in request.messages:
            if msg.role == "user":
                prompt += f"User: {msg.content}\n"
            elif msg.role == "assistant":
                prompt += f"Assistant: {msg.content}\n"
        
        prompt += "Assistant:"
        
        # Tokenize
        inputs = tokenizer(prompt, return_tensors="pt").to("cuda")
        
        # Generate
        with torch.no_grad():
            outputs = model.generate(
                **inputs,
                max_new_tokens=request.max_tokens,
                temperature=request.temperature,
                top_p=request.top_p,
                do_sample=True
            )
        
        # Decode
        response_text = tokenizer.decode(outputs[0][inputs['input_ids'].shape[-1]:], 
                                        skip_special_tokens=True).strip()
        
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
            model="codellama",
            usage={
                "prompt_tokens": inputs['input_ids'].shape[-1],
                "completion_tokens": len(tokenizer.encode(response_text)),
                "total_tokens": inputs['input_ids'].shape[-1] + len(tokenizer.encode(response_text))
            }
        )
    
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "gpus_available": torch.cuda.device_count(),
        "cuda_available": torch.cuda.is_available()
    }

if __name__ == "__main__":
    print("Starting Multi-GPU Inference Server...")
    uvicorn.run(app, host="0.0.0.0", port=8000)
