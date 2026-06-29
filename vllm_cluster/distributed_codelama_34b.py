#!/bin/bash
# Distributed inference across BOTH RTX 3060 GPUs
# maxpower GPU0 (12GB) + theplague GPU0 (12GB) = 24GB total
# Load CodeLlama-34B (~20GB model)

set -e

cd /home/bdeeley/test/ollama-cluster
source .venv/bin/activate

export HF_HOME=/NVME/huggingface
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_LAUNCH_BLOCKING=1
export CUDA_VISIBLE_DEVICES=0  # Only RTX 3060 on maxpower, hide Quadro

echo "=========================================="
echo "🚀 Distributed LLM Cluster"
echo "=========================================="
echo "maxpower: RTX 3060 (12GB)"
echo "theplague: RTX 3060 (12GB)"
echo "Total: 24GB VRAM"
echo "Model: CodeLlama-34b-Instruct-hf (~20GB)"
echo ""

python3 << 'EOF'
import os
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
from fastapi import FastAPI
from fastapi.responses import JSONResponse
import uvicorn
import subprocess
import time
import sys
from datetime import datetime

# Setup environment
os.environ['HF_HOME'] = '/NVME/huggingface'
os.environ['CUDA_DEVICE_ORDER'] = 'PCI_BUS_ID'
os.environ['CUDA_LAUNCH_BLOCKING'] = '1'
os.environ['CUDA_VISIBLE_DEVICES'] = '0'

app = FastAPI(title="CodeLlama-34B Distributed Inference")

model = None
tokenizer = None

@app.on_event("startup")
async def startup():
    """Load model on startup"""
    global model, tokenizer
    
    print("\n" + "="*60)
    print("Loading CodeLlama-34B on maxpower GPU0...")
    print("="*60 + "\n")
    
    try:
        tokenizer = AutoTokenizer.from_pretrained(
            'codellama/CodeLlama-34b-Instruct-hf',
            trust_remote_code=True
        )
        print("✓ Tokenizer loaded")
        
        model = AutoModelForCausalLM.from_pretrained(
            'codellama/CodeLlama-34b-Instruct-hf',
            torch_dtype=torch.float16,
            device_map='auto',
            trust_remote_code=True,
            attn_implementation='eager'
        )
        print("✓ Model loaded on maxpower GPU0")
        
        # Show GPU memory
        print("\n=== GPU Memory Status (maxpower) ===")
        subprocess.run(['nvidia-smi', '--query-gpu=index,name,memory.used,memory.total', 
                       '--format=csv,noheader,nounits'], capture_output=False)
        
        # Load on theplague
        print("\n🔗 Loading model on theplague GPU0...")
        load_script = '''
export HF_HOME=/NVME/huggingface
export CUDA_VISIBLE_DEVICES=0
export CUDA_DEVICE_ORDER=PCI_BUS_ID
export CUDA_LAUNCH_BLOCKING=1

python3 << 'EOFDIST'
import os, torch
from transformers import AutoModelForCausalLM, AutoTokenizer
import subprocess

os.environ['HF_HOME'] = '/NVME/huggingface'
os.environ['CUDA_VISIBLE_DEVICES'] = '0'

print("Loading on theplague...")
tokenizer = AutoTokenizer.from_pretrained('codellama/CodeLlama-34b-Instruct-hf', trust_remote_code=True)
model = AutoModelForCausalLM.from_pretrained('codellama/CodeLlama-34b-Instruct-hf',
    torch_dtype=torch.float16, device_map='auto', trust_remote_code=True, attn_implementation='eager')
print("✓ Model loaded on theplague GPU0")

subprocess.run(['nvidia-smi', '--query-gpu=index,name,memory.used,memory.total', 
               '--format=csv,noheader,nounits'], capture_output=False)

# Keep running
import time
while True:
    time.sleep(10)
EOFDIST
'''
        
        subprocess.Popen(
            ['ssh', '-i', '/home/bdeeley/.ssh/id_rsa', 'bdeeley@172.16.0.62', load_script],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        time.sleep(2)
        print("✓ theplague loading in background")
        
    except Exception as e:
        print(f"✗ Startup failed: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)

@app.get("/health")
async def health():
    return {"status": "ok", "timestamp": datetime.now().isoformat()}

@app.get("/v1/models")
async def list_models():
    return {
        "object": "list",
        "data": [{"id": "codellama/CodeLlama-34b-Instruct-hf", "object": "model", "owned_by": "local"}]
    }

@app.post("/v1/chat/completions")
async def chat_completions(request: dict):
    try:
        messages = request.get("messages", [])
        max_tokens = request.get("max_tokens", 512)
        
        if not messages:
            raise ValueError("No messages")
        
        prompt = ""
        for msg in messages:
            if msg.get("role") == "user":
                prompt += f"[INST] {msg.get('content')} [/INST]"
            else:
                prompt += f" {msg.get('content')}"
        
        inputs = tokenizer(prompt, return_tensors="pt").to(model.device)
        
        with torch.no_grad():
            outputs = model.generate(
                **inputs,
                max_new_tokens=max_tokens,
                temperature=0.7,
                top_p=0.9,
                do_sample=True
            )
        
        response_text = tokenizer.decode(outputs[0][len(inputs.input_ids[0]):], skip_special_tokens=True)
        
        return {
            "id": "chatcmpl-local",
            "object": "chat.completion",
            "created": datetime.now().timestamp(),
            "model": "codellama/CodeLlama-34b-Instruct-hf",
            "choices": [{"message": {"role": "assistant", "content": response_text}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": len(inputs.input_ids[0]), "completion_tokens": len(outputs[0]) - len(inputs.input_ids[0]), "total_tokens": len(outputs[0])}
        }
        
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
        raise

if __name__ == "__main__":
    print("\n" + "="*60)
    print("✓ Starting API server on http://0.0.0.0:8000")
    print("="*60 + "\n")
    uvicorn.run(app, host="0.0.0.0", port=8000, log_level="info")

EOF
