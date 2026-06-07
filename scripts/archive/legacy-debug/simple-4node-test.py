#!/usr/bin/env python3
"""
Simple test to check 4-node placement and instance creation
"""
import requests
import json
import time

def check_state():
    """Get cluster state"""
    return requests.get("http://localhost:52415/state", timeout=2).json()

def main():
    print("╔════════════════════════════════════════════════════════════╗")
    print("║  SIMPLE 4-NODE PLACEMENT TEST                             ║")
    print("╚════════════════════════════════════════════════════════════╝")
    print()
    
    # Check initial state
    state = check_state()
    nodes = state.get('nodeIdentities', [])
    print(f"[1] Cluster has {len(nodes)} nodes")
    for i, nid in enumerate(nodes):
        print(f"    {i+1}. {nid[:20]}...")
    print()
    
    # Request 4-node placement
    print("[2] Requesting 4-node placement...")
    resp = requests.post(
        "http://localhost:52415/place_instance",
        json={
            "model_id": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit",
            "min_nodes": 4
        },
        timeout=5
    )
    print(f"    Status: {resp.status_code}")
    if resp.status_code != 200:
        print(f"    Error: {resp.text}")
        return
    
    # Monitor instance creation
    print()
    print("[3] Monitoring instance creation...")
    time.sleep(3)
    
    state = check_state()
    instances = state.get('instances', [])
    runners = state.get('runners', [])
    
    print(f"    Instances created: {len(instances)}")
    for inst in instances:
        if isinstance(inst, dict):
            inst_id = inst.get('instance_id', 'unknown')
        else:
            inst_id = str(inst)[:12]
        print(f"      - {inst_id[:12]}...")
    
    print()
    print(f"    Runners created: {len(runners)}")
    
    # Group runners by status
    status_map = {}
    for r in runners:
        if isinstance(r, dict):
            status = list(r.keys())[0] if r else "Unknown"
        else:
            status = str(r)
        status_map[status] = status_map.get(status, 0) + 1
    
    for status, count in sorted(status_map.items()):
        print(f"      - {status}: {count}")
    
    print()
    print("[4] Instance details:")
    print(f"    Instances data type: {type(instances)}")
    print(f"    Raw instances: {json.dumps(instances, default=str, indent=2)}")
    
    print()
    print("[5] Analysis:")
    print(f"    Total instances: {len(instances)}")
    print(f"    Actual runners created: {len(runners)}")

if __name__ == "__main__":
    main()
