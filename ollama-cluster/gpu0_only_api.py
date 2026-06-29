import asyncio, os, logging
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse
import uvicorn
from llama_cpp import Llama

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

GGUF_PATH = "/NVME/models/gguf/mistral-7b-instruct-v0.2.Q4_K_M.gguf"
app = FastAPI()
llm = None

def load_model():
    global llm
    if not Path(GGUF_PATH).exists():
        raise FileNotFoundError(f"Model not found: {GGUF_PATH}")
    logger.info("Loading Mistral-7B with ALL 32 layers on GPU0 (RTX 3060)")
    llm = Llama(model_path=GGUF_PATH, n_gpu_layers=32, n_ctx=2048, n_batch=128, n_threads=4, verbose=False)
    logger.info("✅ Fully loaded on GPU0, minimal CPU overhead")

@app.on_event("startup")
async def startup():
    try:
        load_model()
    except Exception as e:
        logger.error(f"Failed to load: {e}")
        raise

@app.post("/v1/chat/completions")
async def chat(request: dict):
    if llm is None:
        raise HTTPException(status_code=503, detail="Model not loaded")
    try:
        messages = request.get("messages", [])
        prompt = "".join([f"[INST] {m['content']} [/INST]" if m['role']=="user" else f" {m['content']}" for m in messages])
        output = llm(prompt, max_tokens=request.get("max_tokens", 100), temperature=request.get("temperature", 0.7))
        return JSONResponse({
            "id": "chatcmpl-local",
            "object": "chat.completion",
            "choices": [{"message": {"content": output["choices"][0]["text"]}}]
        })
    except Exception as e:
        logger.error(f"Error: {e}")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000)
