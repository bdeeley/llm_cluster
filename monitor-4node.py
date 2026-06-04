#!/usr/bin/env python3
"""
Monitor runner state progression during 4-node placement test
Captures status every 2 seconds to see where runners get stuck
"""
import requests
import json
import time
import sys

def get_state():
    try:
        return requests.get("http://localhost:52415/state", timeout=2).json()
    except:
        return None

def count_by_status(runners_dict):
    """Group runners by their status"""
    statuses = {}
    # runners_dict is Mapping[RunnerId, RunnerStatus]
    if isinstance(runners_dict, dict):
        for runner_id, status_obj in runners_dict.items():
            # status_obj is tagged, should be like {"RunnerReady": {...}}
            if isinstance(status_obj, dict):
                status_name = list(status_obj.keys())[0] if status_obj else "Unknown"
            else:
                status_name = str(status_obj)
            statuses[status_name] = statuses.get(status_name, 0) + 1
    else:
        statuses["Unknown"] = len(runners_dict)
    return statuses

def main():
    print("╔════════════════════════════════════════════════════════════╗")
    print("║  4-NODE PLACEMENT DIAGNOSTICS - LIVE RUNNER MONITORING     ║")
    print("╚════════════════════════════════════════════════════════════╝")
    print()
    
    # Start test
    print("[0] Requesting 4-node placement...")
    resp = requests.post(
        "http://localhost:52415/place_instance",
        json={
            "model_id": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit",
            "min_nodes": 4
        },
        timeout=5
    )
    print(f"    Status: {resp.status_code}\n")
    
    # Monitor for 60 seconds
    print("Time  | Instances | Runners | Ready | Status Breakdown")
    print("------|-----------|---------|-------|------------------")
    
    for elapsed in range(0, 61, 2):
        state = get_state()
        if not state:
            print(f"{elapsed:3d}s | --ERROR-- | stopped |  --  | No connection")
            continue
        
        instances = len(state.get('instances', {}))
        runners_dict = state.get('runners', {})
        runner_count = len(runners_dict)
        
        statuses = count_by_status(runners_dict)
        ready_count = statuses.get('RunnerReady', 0)
        
        # Format status string
        status_items = []
        for status in ['RunnerIdle', 'RunnerConnecting', 'RunnerConnected', 'RunnerLoading', 'RunnerLoaded', 'RunnerWarmingUp', 'RunnerReady', 'RunnerFailed']:
            if status in statuses:
                status_items.append(f"{status}:{statuses[status]}")
        status_str = " ".join(status_items[:2])  # Show first 2
        
        print(f"{elapsed:3d}s | {instances:9d} | {runner_count:7d} | {ready_count:5d} | {status_str}")
        
        time.sleep(2)
    
    print()
    print("Final state:")
    state = get_state()
    if state:
        instances = len(state.get('instances', {}))
        runners_dict = state.get('runners', {})
        runners = len(runners_dict)
        statuses = count_by_status(runners_dict)
        print(f"  Instances: {instances}")
        print(f"  Runners: {runners}")
        print(f"  Status breakdown: {json.dumps(statuses, indent=4)}")

if __name__ == "__main__":
    main()
