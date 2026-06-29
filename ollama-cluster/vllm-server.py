#!/usr/bin/env python
"""
vLLM wrapper that fixes fork+CUDA initialization issue.
Sets torch.multiprocessing spawn method BEFORE importing vllm.
"""
import sys
import torch.multiprocessing as mp
import runpy

# CRITICAL: Set spawn method BEFORE importing vLLM to fix fork+CUDA issue
mp.set_start_method('spawn', force=True)

if __name__ == "__main__":
    # Now run the api_server module with spawn already configured
    runpy.run_module('vllm.entrypoints.openai.api_server', run_name='__main__')
