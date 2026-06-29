#!/bin/bash
# Start distributed CodeLlama-34B cluster
# maxpower GPU0 + theplague GPU0 = 24GB VRAM
# Model: CodeLlama-34b-Instruct-hf (~20GB)

cd "$(dirname "$0")" || exit 1

source /home/bdeeley/test/.venv/bin/activate

echo "Starting CodeLlama-34B Distributed Cluster..."
echo ""

python3 cluster.py
