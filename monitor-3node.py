#!/usr/bin/env python3
"""Monitor 3-node placement test."""

import requests
import json
import time
import sys
from datetime import datetime

def monitor_3node_placement():
    """Request and monitor 3-node model placement."""
    try:
        print("\n" + "="*60)
        print(" 3-NODE PLACEMENT TEST")
        print("="*60 + "\n")
        
        print("[0] Requesting 3-node placement...")
        resp = requests.post(
            "http://localhost:52415/place_instance",
            json={
                "model_id": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit",
                "min_nodes": 3
            },
            timeout=5
        )
        print(f"    Status: {resp.status_code}\n")
        
        # Monitor for 70 seconds
        print("Time | Instances | Runners | Ready | Status Breakdown")
        print("-----|-----------|---------|-------|------------------")
        
        start_time = time.time()
        timeout = 70
        
        while time.time() - start_time < timeout:
            elapsed = int(time.time() - start_time)
            
            try:
                state = requests.get("http://localhost:52415/state", timeout=2).json()
            except:
                continue
                
            try:
                instances = len(state.get('instances', []))
                runners = len(state.get('runners', []))
                ready_count = sum(1 for r in state.get('runners', []) 
                                if (isinstance(r.get('current_status'), dict) and 
                                    r.get('current_status', {}).get('type') == 'RunnerReady') or
                                   (isinstance(r.get('current_status'), str) and 'RunnerReady' in str(r.get('current_status'))))
                
                # Count runner states
                status_counts = {}
                for runner in state.get('runners', []):
                    if isinstance(runner.get('current_status'), dict):
                        status_type = runner.get('current_status', {}).get('type', 'Unknown')
                    else:
                        status_type = str(runner.get('current_status', 'Unknown')).replace('RunnerStatus.', '')
                    status_counts[status_type] = status_counts.get(status_type, 0) + 1
                
                # Format status breakdown
                status_str = " ".join(f"{k}:{v}" for k, v in sorted(status_counts.items()) if v > 0)
                
                print(f"{elapsed:3d}s | {instances:9d} | {runners:7d} | {ready_count:5d} | {status_str}")
            except Exception as e:
                print(f"  {elapsed:3d}s | Error parsing state: {str(e)[:40]}", file=sys.stderr)
                continue
            
            time.sleep(2)
            
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)

if __name__ == "__main__":
    monitor_3node_placement()
