#!/usr/bin/env python3
"""
Diagnostic script to understand 4-node ring topology formation issues.
Checks network connectivity, configuration, and ring initialization.
"""

import subprocess
import json
import sys
from typing import Optional

def run_cmd(cmd: str, host: Optional[str] = None) -> tuple[int, str, str]:
    """Run command locally or on remote host via SSH."""
    if host:
        cmd = f'ssh bdeeley@{host} "{cmd}"'
    
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=10)
    return result.returncode, result.stdout, result.stderr

def diagnose_node(node_name: str, ip: str):
    """Diagnose a single node."""
    print(f"\n{'='*60}")
    print(f"Diagnosing node: {node_name} ({ip})")
    print('='*60)
    
    # Check if node is reachable
    print("\n1. Network connectivity:")
    rc, out, err = run_cmd(f"ping -c 1 {ip}")
    print(f"   Ping {ip}: {'✓' if rc == 0 else '✗'}")
    
    # Check exo service status
    print("\n2. EXO service status:")
    rc, out, err = run_cmd("systemctl status exo-worker.service --no-pager | head -5", host=ip)
    if "running" in out.lower() or "active" in out.lower():
        print(f"   Service: ✓ RUNNING")
    else:
        print(f"   Service: ✗ NOT RUNNING")
        print(f"   Status: {out}")
    
    # Check recent logs for ring init
    print("\n3. Recent ring initialization logs:")
    rc, out, err = run_cmd(
        "journalctl -u exo-worker.service -n 100 --no-pager 2>&1 | grep -i 'rank\\|distributed\\|ring\\|connecting' | tail -5",
        host=ip
    )
    if out:
        for line in out.strip().split('\n')[:5]:
            print(f"   {line[:120]}")
    else:
        print("   (No relevant logs found)")
    
    # Check if any errors
    print("\n4. Recent error logs:")
    rc, out, err = run_cmd(
        "journalctl -u exo-worker.service -n 50 --no-pager 2>&1 | grep -i 'error\\|failed\\|exception' | tail -3",
        host=ip
    )
    if out:
        for line in out.strip().split('\n')[:3]:
            print(f"   {line[:120]}")
    else:
        print("   (No errors found)")

def main():
    nodes = [
        ("Master (maxpower)", "172.16.0.174"),
        ("Remote1 (theplague)", "172.16.0.175"),
        ("Remote2 (debian)", "172.16.0.14"),
    ]
    
    print("\n" + "="*60)
    print("4-NODE RING TOPOLOGY DIAGNOSTICS")
    print("="*60)
    
    # Check local node (master) without SSH
    print(f"\n{'='*60}")
    print("Local node: maxpower (Master)")
    print('='*60)
    
    print("\n1. Recent ConnectToGroup logs:")
    result = subprocess.run(
        "sudo journalctl -u exo-worker.service -n 300 --no-pager 2>&1 | grep 'rank.*About to call' | tail -10",
        shell=True, capture_output=True, text=True
    )
    out = result.stdout
    if out:
        for line in out.strip().split('\n'):
            if line:
                print(f"   {line[:120]}")
    
    print("\n2. MLX Ring verbose output:")
    result = subprocess.run(
        "sudo journalctl -u exo-worker.service -n 200 --no-pager 2>&1 | grep '\\[ring\\]' | tail -10",
        shell=True, capture_output=True, text=True
    )
    out = result.stdout
    if out:
        for line in out.strip().split('\n'):
            if line:
                print(f"   {line[:120]}")
    else:
        print("   (No [ring] messages found - ring init not reached)")
    
    print("\n3. Latest runner connect attempts:")
    result = subprocess.run(
        "sudo journalctl -u exo-worker.service -n 100 --no-pager 2>&1 | grep 'ConnectToGroup: Starting' | tail -5",
        shell=True, capture_output=True, text=True
    )
    out = result.stdout
    if out:
        lines = out.strip().split('\n')
        print(f"   Found {len(lines)} ConnectToGroup attempts")
        for line in lines:
            if line:
                # Extract timestamp
                parts = line.split('|')
                if len(parts) >= 3:
                    timestamp = parts[0].strip()
                    message = '|'.join(parts[2:]).strip()
                    print(f"   {timestamp}: {message[:80]}")
    
    # Try to check remote nodes (may fail if SSH not configured)
    print(f"\n{'='*60}")
    print("Checking remote nodes (requires SSH)")
    print('='*60)
    
    for node_name, ip in nodes[1:]:
        try:
            diagnose_node(node_name, ip)
        except Exception as e:
            print(f"\n✗ Could not diagnose {node_name} ({ip}): {str(e)}")
    
    print(f"\n{'='*60}")
    print("SUMMARY")
    print('='*60)
    print("""
The key issue appears to be that mx.distributed.init(backend="ring") is HANGING.
This typically happens when:
1. Ring hosts cannot reach each other on configured ports
2. Network configuration/firewall blocking the connections
3. Ephemeral ports allocated don't match on all nodes
4. Host file has incorrect IP addresses or ports

To debug further:
1. Check if hosts_by_node has correct IP:port pairs for all 4 nodes
2. Verify all nodes can ping and curl each other on the ring ports
3. Check if ephemeralPort allocation is the same on all nodes
4. Enable MLX debug logging (MLX_RING_VERBOSE=1 already enabled)
5. Check remote node logs to see if ranks 0, 1, 3 are initializing

For 2-node testing:
- Current 2-node tests work (single GPU configurations)
- Try running with just master + one remote node (min_nodes=2)
""")

if __name__ == "__main__":
    main()
