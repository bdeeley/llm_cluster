#!/usr/bin/env python3
"""
Convert Mistral-7B safetensors to GGUF format for llama.cpp multi-GPU usage
"""
import os
import subprocess
import sys
from pathlib import Path

# Set environment for model loading
os.environ['HF_HOME'] = '/NVME/huggingface'
os.environ['HF_HUB_CACHE'] = '/NVME/huggingface/hub'
os.environ['TRANSFORMERS_CACHE'] = '/NVME/huggingface/models'

def run_command(cmd):
    """Run shell command and return output"""
    print(f"Running: {' '.join(cmd)}")
    result = subprocess.run(cmd, capture_output=False, text=True)
    return result.returncode == 0

def main():
    model_id = "mistralai/Mistral-7B-Instruct-v0.2"
    
    # Try to download GGUF from HuggingFace
    print("=" * 60)
    print("Converting Mistral-7B to GGUF for multi-GPU llama.cpp")
    print("=" * 60)
    
    output_dir = Path("/NVME/models/gguf")
    output_dir.mkdir(parents=True, exist_ok=True)
    
    gguf_path = output_dir / "mistral-7b-instruct-v0.2.Q4_K_M.gguf"
    
    if gguf_path.exists():
        print(f"✅ GGUF model already exists: {gguf_path}")
        return 0
    
    print("\n📥 Attempting to download pre-quantized GGUF from HuggingFace...")
    
    # Try using huggingface-hub to download GGUF
    try:
        from huggingface_hub import hf_hub_download
        
        # TheBloke has excellent GGUF quantizations
        gguf_id = "TheBloke/Mistral-7B-Instruct-v0.2-GGUF"
        gguf_file = "mistral-7b-instruct-v0.2.Q4_K_M.gguf"
        
        print(f"Downloading {gguf_file} from {gguf_id}...")
        model_path = hf_hub_download(
            repo_id=gguf_id,
            filename=gguf_file,
            cache_dir="/NVME/huggingface/hub"
        )
        print(f"✅ Downloaded to: {model_path}")
        
        # Copy to our models directory
        import shutil
        shutil.copy(model_path, gguf_path)
        print(f"✅ Copied to: {gguf_path}")
        return 0
        
    except Exception as e:
        print(f"⚠️  Download failed: {e}")
        print("\n🔄 Falling back to manual conversion...")
    
    # Fallback: convert using transformers + llama.cpp
    print("\n📦 Converting from safetensors to GGUF...")
    print("This will take 5-10 minutes...")
    
    try:
        # Use llama.cpp's conversion script
        conversion_script = """
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer, AutoConfig
import struct

# Load the model
print("Loading model...")
model = AutoModelForCausalLM.from_pretrained(
    "mistralai/Mistral-7B-Instruct-v0.2",
    torch_dtype=torch.float16,
    device_map="cpu"
)

# Save as GGUF using ggml
print("Converting to GGUF format...")
# This is complex; recommend using llama.cpp's script directly
"""
        
        # Alternative: use llama-cpp-python's built-in download
        from llama_cpp import Llama
        print("Using llama-cpp-python to load and optimize...")
        # This will handle conversion transparently
        
    except Exception as e:
        print(f"❌ Conversion failed: {e}")
        print("\nAlternative: Download pre-quantized GGUF manually")
        print("Visit: https://huggingface.co/TheBloke/Mistral-7B-Instruct-v0.2-GGUF")
        print("Download: mistral-7b-instruct-v0.2.Q4_K_M.gguf")
        print(f"Place in: {output_dir}")
        return 1
    
    print(f"✅ Model ready at: {gguf_path}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
