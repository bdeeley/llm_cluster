#!/usr/bin/env python
"""
Load a model across all local GPUs using HuggingFace device_map='auto'.
Automatically distributes model layers across maxpower GPUs (0,1).
Can extend to theplague (GPU 2) with Ray.
"""
import torch
from transformers import AutoTokenizer, AutoModelForCausalLM
import sys

def load_model_distributed(model_name="mistralai/Mistral-7B-Instruct-v0.2", dtype=torch.bfloat16):
    """
    Load model using HuggingFace device_map='auto' for automatic GPU distribution.
    Distributes model layers across all available local GPUs.
    """
    
    print(f"\n{'='*60}")
    print(f"Loading {model_name}")
    print(f"{'='*60}")
    
    # Load tokenizer
    print("Loading tokenizer...")
    tokenizer = AutoTokenizer.from_pretrained(model_name, trust_remote_code=True)
    
    # Load model with automatic GPU distribution
    print(f"Loading model with device_map='auto'...")
    print(f"Available GPUs: {torch.cuda.device_count()}")
    
    model = AutoModelForCausalLM.from_pretrained(
        model_name,
        torch_dtype=dtype,
        trust_remote_code=True,
        device_map="auto",  # Automatically distribute across all GPUs
        attn_implementation="eager",  # Disable FlashAttention (not supported on Pascal)
    )
    
    print(f"✓ Model loaded across local GPUs")
    print(f"\n  GPU Memory allocation:")
    for i in range(torch.cuda.device_count()):
        allocated = torch.cuda.memory_allocated(i) / 1e9
        reserved = torch.cuda.memory_reserved(i) / 1e9
        print(f"    GPU {i}: {allocated:.1f}GB allocated, {reserved:.1f}GB reserved")
    
    return model, tokenizer


def test_inference(model, tokenizer, prompt="Hello, how are you?", max_tokens=50):
    """Test inference with the distributed model."""
    print(f"\n{'='*60}")
    print(f"Testing inference")
    print(f"{'='*60}")
    print(f"Prompt: {prompt}\n")
    
    inputs = tokenizer(prompt, return_tensors="pt").to("cuda")
    
    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=max_tokens,
            temperature=0.7,
            top_p=0.95,
            do_sample=True
        )
    
    response = tokenizer.decode(outputs[0], skip_special_tokens=True)
    print(f"Response:\n{response}\n")
    
    return response


if __name__ == "__main__":
    # Choose model based on available VRAM
    model_name = "mistralai/Mistral-7B-Instruct-v0.2"
    
    if len(sys.argv) > 1:
        model_name = sys.argv[1]
    
    print(f"\n>>> Multi-GPU Distributed Inference <<<")
    print(f"Available local GPUs (maxpower): {torch.cuda.device_count()}")
    print(f"Local VRAM: ~36GB (12GB RTX3060 + 24GB P6000)")
    print(f"Extended VRAM (with theplague): ~48GB (add 12GB RTX3060)")
    
    try:
        model, tokenizer = load_model_distributed(model_name)
        test_inference(model, tokenizer)
        print("✓ SUCCESS: Model loaded and running across GPUs")
        
    except Exception as e:
        print(f"\n✗ ERROR: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
