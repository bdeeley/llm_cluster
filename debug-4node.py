#!/usr/bin/env python3
"""
Debug 4-node placement: why 2 instances and 10 runners?
"""
import requests
import json
import sys

try:
    print("Requesting 4-node placement...", file=sys.stderr)
    resp = requests.post(
        "http://localhost:52415/place_instance",
        json={
            "model_id": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit",
            "min_nodes": 4
        },
        timeout=5
    )
    print(f"Status: {resp.status_code}", file=sys.stderr)
    
    print("Getting cluster state...", file=sys.stderr)
    state = requests.get("http://localhost:52415/state", timeout=2).json()
    
    instances = state.get('instances', [])
    runners = state.get('runners', [])
    
    print(f"\n{'='*60}", file=sys.stdout)
    print(f"INSTANCES: {len(instances)}", file=sys.stdout)
    print(f"RUNNERS: {len(runners)}", file=sys.stdout)
    print(f"{'='*60}\n", file=sys.stdout)
    
    print(json.dumps(state, default=str, indent=2), file=sys.stdout)

except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
