#!/usr/bin/env python3
"""
Diagnostic script to trace 4-node placement and runner allocation
"""
import requests
import time
import subprocess
import json

def check_cluster_state():
    """Get current cluster state"""
    try:
        state = requests.get("http://localhost:52415/state", timeout=2).json()
        return state
    except:
        return None

def clear_logs():
    """Clear master logs"""
    subprocess.run(["sudo", "rm", "-rf", "/home/bdeeley/.local/share/exo-master/event_log"], 
                   capture_output=True)
    subprocess.run(["sudo", "mkdir", "-p", "/home/bdeeley/.local/share/exo-master/event_log"],
                   capture_output=True)
    time.sleep(2)

def get_placement_logs():
    """Get placement logs from master"""
    result = subprocess.run(
        ["sudo", "journalctl", "-u", "exo.service", "-n", "200", "--no-pager"],
        capture_output=True,
        text=True
    )
    lines = result.stdout.split('\n')
    # Filter to placement-related lines
    placement_lines = [l for l in lines if 'PLACEMENT' in l or 'Shard' in l or 'runner' in l.lower()]
    return placement_lines

def main():
    print("╔═════════════════════════════════════════════════════════════════╗")
    print("║  4-NODE PLACEMENT DIAGNOSTICS                                  ║")
    print("╚═════════════════════════════════════════════════════════════════╝")
    print()
    
    print("[1] Clearing logs and preparing cluster...")
    clear_logs()
    time.sleep(3)
    
    state = check_cluster_state()
    if not state:
        print("✗ Cluster not responding. Start cluster first.")
        return
    
    nodes = len(state.get('nodeIdentities', []))
    print(f"✓ Cluster ready: {nodes} nodes")
    print()
    
    print("[2] Requesting 4-node placement...")
    try:
        resp = requests.post(
            "http://localhost:52415/place_instance",
            json={
                "model_id": "mlx-community/Llama-3.1-Nemotron-Nano-4B-v1.1-8bit",
                "min_nodes": 4
            },
            timeout=5
        )
        print(f"✓ Request accepted (status: {resp.status_code})")
    except Exception as e:
        print(f"✗ Request failed: {e}")
        return
    
    print()
    print("[3] Monitoring state changes...")
    print()
    
    prev_runners = 0
    for elapsed in range(1, 31):
        state = check_cluster_state()
        if not state:
            continue
        
        runners = state.get('runners', [])
        instances = state.get('instances', [])
        ready_count = sum(1 for r in runners if 'RunnerReady' in r)
        
        # Show runner statuses
        statuses = {}
        for r in runners:
            status = list(r.keys())[0] if r else "Unknown"
            statuses[status] = statuses.get(status, 0) + 1
        
        status_str = ", ".join(f"{k}:{v}" for k,v in sorted(statuses.items()))
        
        # Only print if something changed
        if len(runners) != prev_runners:
            print(f"[{elapsed:2d}s] Runners: {len(runners)}/4 | {status_str}")
            prev_runners = len(runners)
        
        time.sleep(1)
    
    print()
    print("[4] Master placement logs:")
    print("─" * 70)
    logs = get_placement_logs()
    for line in logs[-30:]:  # Last 30 placement-related lines
        if line.strip():
            print(line)
    
    print()
    print("[5] Final state:")
    state = check_cluster_state()
    if state:
        runners = state.get('runners', [])
        print(f"Total runners: {len(runners)}")
        print(f"Ready runners: {sum(1 for r in runners if 'RunnerReady' in r)}")
        print(f"Instances: {len(state.get('instances', []))}")
        
        # Show all runner statuses
        print("\nRunner status breakdown:")
        status_map = {}
        for r in runners:
            status = list(r.keys())[0] if r else "Unknown"
            if status not in status_map:
                status_map[status] = []
            status_map[status].append(r)
        
        for status, runners_with_status in sorted(status_map.items()):
            print(f"  {status}: {len(runners_with_status)}")

if __name__ == "__main__":
    main()
