#!/usr/bin/env python3
import os
import sys
import torch.multiprocessing as mp

# Fix CUDA fork issue by using spawn
mp.set_start_method('spawn', force=True)

# Now run vLLM
os.environ['CUDA_DEVICE_ORDER'] = 'PCI_BUS_ID'
os.environ['CUDA_LAUNCH_BLOCKING'] = '1'

from vllm.entrypoints.openai.api_server import main

if __name__ == '__main__':
    sys.argv = [
        'vllm',
        '--model', 'mistralai/Mistral-7B-Instruct-v0.2',
        '--tensor-parallel-size', '2',
        '--port', '8000',
        '--host', '0.0.0.0',
        '--seed', '42',
    ]
    main()
