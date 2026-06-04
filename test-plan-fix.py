#!/usr/bin/env python3
"""
Direct test of the ConnectToGroup task generation fix in worker/plan.py
"""

import sys
sys.path.insert(0, '/home/bdeeley/exo/src')

from exo.shared.types.worker.runners import RunnerIdle, RunnerConnecting
from exo.shared.types.tasks import ConnectToGroup
from exo.worker.plan import _init_distributed_backend

# Create proper mock classes that match the expected structure
class MockShardAssignments:
    def __init__(self, runner_ids, is_multi_node=True):
        self.runner_to_shard = {rid: None for rid in runner_ids}
        # runner_to_shard keys are the global runner IDs for the instance

class MockInstance:
    def __init__(self, instance_id, shard_assignments):
        self.instance_id = instance_id
        self.shard_assignments = shard_assignments

class MockShard:
    def __init__(self, device_rank, world_size):
        self.device_rank = device_rank
        self.world_size = world_size

class MockBoundInstance:
    def __init__(self, instance, runner_id, device_rank, world_size):
        self.instance = instance
        self.bound_runner_id = runner_id
        self.bound_shard = MockShard(device_rank, world_size)

class MockRunner:
    def __init__(self, status, bound_instance):
        self.status = status
        self.bound_instance = bound_instance

print("=" * 70)
print("Test: _init_distributed_backend with missing runners in all_runners")
print("=" * 70)

# Test Case 1: Simple 2-node case, both runners present
print("\n[Test 1] Both runners present in global state (baseline)")
print("  Setup: 2-node instance with 2 runners, both idle locally and globally")
runners = {
    'runner1': MockRunner(
        RunnerIdle(),
        MockBoundInstance(
            MockInstance('inst1', MockShardAssignments(['runner1', 'runner2'])),
            'runner1',
            device_rank=0,
            world_size=2
        )
    ),
}
all_runners = {
    'runner1': RunnerIdle(),
    'runner2': RunnerIdle(),  # Both runners in global state
}
task = _init_distributed_backend(runners, all_runners)
print(f"  device_rank=0, world_size=2 (accepting_ranks should be True)")
print(f"  Result: {task.__class__.__name__ if task else 'None'}")
assert isinstance(task, ConnectToGroup), f"FAIL: Expected ConnectToGroup, got {task}"
print(f"  ✓ PASS")

# Test Case 2: Runner2 missing from global state (THE FIX)
print("\n[Test 2] Runner2 MISSING from global state (the bug case - now fixed!)")
print("  Setup: 2-node instance, runner1 idle locally, but runner2 not yet in global state")
runners = {
    'runner1': MockRunner(
        RunnerIdle(),
        MockBoundInstance(
            MockInstance('inst1', MockShardAssignments(['runner1', 'runner2'])),
            'runner1',
            device_rank=0,
            world_size=2
        )
    ),
}
all_runners = {
    'runner1': RunnerIdle(),
    # 'runner2' is MISSING - this is the critical case!
}
task = _init_distributed_backend(runners, all_runners)
print(f"  With the fix: Missing runners treated as RunnerIdle()")
print(f"  Result: {task.__class__.__name__ if task else 'None'}")
assert isinstance(task, ConnectToGroup), f"FAIL: Expected ConnectToGroup, got {task}"
print(f"  ✓ PASS - Fix works!")

# Test Case 3: Last rank (device_rank=1) - can't proceed without other ranks connecting
print("\n[Test 3] Last rank waiting for other rank to be RunnerConnecting")
print("  Setup: Runner2 is last rank (device_rank=1), needs runner1 to be RunnerConnecting")
runners = {
    'runner2': MockRunner(
        RunnerIdle(),
        MockBoundInstance(
            MockInstance('inst1', MockShardAssignments(['runner1', 'runner2'])),
            'runner2',
            device_rank=1,
            world_size=2
        )
    ),
}
all_runners = {
    'runner2': RunnerIdle(),
    'runner1': RunnerIdle(),  # Other rank is only idle, not connecting
}
task = _init_distributed_backend(runners, all_runners)
print(f"  device_rank=1, world_size=2 (last rank waits for connecting_rank_ready)")
print(f"  Result: {task.__class__.__name__ if task else 'None'}")
assert task is None, f"FAIL: Expected None (waiting for runner1 to connect), got {task}"
print(f"  ✓ PASS - Last rank correctly waits")

# Test Case 4: Last rank when other runner has connected
print("\n[Test 4] Last rank when other runner is RunnerConnecting")
print("  Setup: Runner2 is last rank, runner1 is already RunnerConnecting")
runners = {
    'runner2': MockRunner(
        RunnerIdle(),
        MockBoundInstance(
            MockInstance('inst1', MockShardAssignments(['runner1', 'runner2'])),
            'runner2',
            device_rank=1,
            world_size=2
        )
    ),
}
all_runners = {
    'runner2': RunnerIdle(),
    'runner1': RunnerConnecting(),  # Other rank is connecting!
}
task = _init_distributed_backend(runners, all_runners)
print(f"  device_rank=1, world_size=2, runner1 is RunnerConnecting")
print(f"  Result: {task.__class__.__name__ if task else 'None'}")
assert isinstance(task, ConnectToGroup), f"FAIL: Expected ConnectToGroup, got {task}"
print(f"  ✓ PASS")

print("\n" + "=" * 70)
print("All tests passed! The fix correctly:")
print("1. Assumes missing runners are RunnerIdle when checking first condition")
print("2. Allows non-last ranks to send ConnectToGroup immediately")
print("3. Allows last rank to send when other ranks are RunnerConnecting")
print("=" * 70)
