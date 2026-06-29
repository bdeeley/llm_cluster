import asyncio
import os
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
import uvicorn
from llama_cpp import Llama

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

GGUF_PATH = "/NVME/models/gguf/mistral-7b-instruct-v0.2.Q4_K_M.gguf"
N_GPU_LAYERS = 32  # Put ALL 32 layers on RTX 3060 only

app = FastAPI()
llm = None

def load_model():
    global llm
    if not Path(GGUF_PATH).exists():
        raise FileNotFoundError(f"Model not found at {GGUF_PATH}")
    
    print(f"Loading all 32 layers on GPU0 (RTX 3060 only) - avoiding CPU")
    llm = Llama(
        model_path=GGUF_PATH,
        n_gpu_layers=N_GPU_LAYERS,
        n_ctx=2048,
        n_batch=128,
        n_threads=4,  # MINIMAL CPU threads, almost everything on GPU
        verbose=False
    )
    print("✅ Model fully loaded on GPU0")

@app.on_event("startup")
async def startup():
    load_model()

@app.post("/v1/chat/completions")
async def chat(request: dict):
    if llm is None:
        raise HTTPException(status_code=503)
    messages = request.get("messages", [])
    prompt = "".join([f"[INST] {m['content']} [/INST]" if m['role']=="user" else f" {m['content']}" for m in messages])
    output = llm(prompt, max_tokens=request.get("max_tokens", 100), temperature=request.get("temperature", 0.7))
    return JSONResponse({"id": "local", "object": "chat.completion", "choices": [{"message": {"content": output["choices"][0]["text"]}}]})

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
