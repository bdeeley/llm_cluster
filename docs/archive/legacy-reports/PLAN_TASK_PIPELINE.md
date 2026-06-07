# EXO Plan() Function & Task Delivery Pipeline

## Overview
The `plan()` function orchestrates task generation for runner subprocesses. This document traces the complete pipeline from plan() returning a Task to that Task being received and processed by a runner subprocess.

---

## 1. Plan Function Definition

**File:** [`/home/bdeeley/exo/src/exo/worker/plan.py`](src/exo/worker/plan.py)

```python
def plan(
    node_id: NodeId,
    runners: Mapping[RunnerId, RunnerSupervisor],
    global_download_status: Mapping[NodeId, Sequence[DownloadProgress]],
    instances: Mapping[InstanceId, Instance],
    all_runners: Mapping[RunnerId, RunnerStatus],  # all global
    tasks: Mapping[TaskId, Task],
    input_chunk_buffer: Mapping[CommandId, Mapping[int, InputImageChunk]],
    image_cache: Mapping[Base64ImageHash, Base64Image],
    instance_backoff: KeyedBackoff[InstanceId],
    download_backoff: KeyedBackoff[ModelId],
) -> Task | None:
```

**Returns:** `Task | None` - Returns a Task like `ConnectToGroup`, `LoadModel`, `StartWarmup`, `TextGeneration`, etc., or None if no action needed.

**Key Helper Functions:**
- `_cancel_tasks()` - Returns `CancelTask` if task needs cancellation
- `_kill_runner()` - Returns `Shutdown` if runner's instance no longer exists
- `_create_runner()` - Returns `CreateRunner` for new instances
- `_model_needs_download()` - Returns `DownloadModel` if model not yet downloaded
- `_init_distributed_backend()` - Returns `ConnectToGroup` for distributed ring initialization
- `_load_model()` - Returns `LoadModel` when all shards are ready
- `_ready_to_warmup()` - Returns `StartWarmup` when model is loaded
- `_pending_tasks()` - Returns pending inference tasks (`TextGeneration`, `ImageGeneration`, `ImageEdits`)

---

## 2. Plan Function Invocation

**File:** [`/home/bdeeley/exo/src/exo/worker/main.py` - Worker class](src/exo/worker/main.py)

### 2.1 Where plan() is Called

```python
class Worker:
    async def plan_step(self):
        while True:
            await anyio.sleep(0.1)
            task: Task | None = plan(
                self.node_id,
                self.runners,
                self.state.downloads,
                self.state.instances,
                self.state.runners,
                self.state.tasks,
                self.input_chunk_buffer,
                self.image_cache,
                self._instance_backoff,
                self._download_backoff,
            )
            if task is None:
                continue
            # ... Task handling (see section 3)
```

**Location:** Lines ~195-210 in `worker/main.py`

**Execution Context:**
- Called in an async loop every 0.1 seconds
- Part of the Worker's TaskGroup that runs concurrently with other tasks
- Started via `async with self._tg as tg: tg.start_soon(self.plan_step)`

---

## 3. Task Routing & Dispatch

**File:** [`/home/bdeeley/exo/src/exo/worker/main.py` - plan_step() method](src/exo/worker/main.py#L195)

### 3.1 Task Type Matching

```python
match task:
    case CreateRunner():
        await self._create_supervisor(task)
        self._instance_backoff.record_attempt(task.instance_id)
        await self.event_sender.send(
            TaskStatusUpdated(task_id=task.task_id, task_status=TaskStatus.Complete)
        )
    
    case DownloadModel(shard_metadata=shard):
        # Forward to download coordinator
        await self.download_command_sender.send(...)
    
    case Shutdown(runner_id=runner_id):
        runner = self.runners.pop(runner_id)
        with fail_after(3):
            await runner.start_task(task)  # <-- Direct send
        runner.shutdown()
    
    case CancelTask(cancelled_task_id=..., runner_id=...):
        await self.runners[runner_id].cancel_task(cancelled_task_id)
    
    case LoadModel() | ConnectToGroup() | StartWarmup() | TextGeneration() | ...:
        await self._start_runner_task(task)  # <-- Via runner supervisor
```

### 3.2 Core Dispatch Method

```python
async def _start_runner_task(self, task: Task):
    if (instance := self.state.instances.get(task.instance_id)) is not None:
        await self.runners[
            instance.shard_assignments.node_to_runner[self.node_id]
        ].start_task(task)
```

**Key Points:**
- Retrieves the appropriate `RunnerSupervisor` from `self.runners` dict
- Calls `start_task(task)` on the supervisor
- This is the entry point to the task transmission pipeline

---

## 4. RunnerSupervisor Task Transmission

**File:** [`/home/bdeeley/exo/src/exo/worker/runner/supervisor.py`](src/exo/worker/runner/supervisor.py)

### 4.1 RunnerSupervisor Creation (Channel Setup)

```python
@classmethod
async def create(
    cls,
    *,
    bound_instance: BoundInstance,
    event_sender: Sender[Event],
    initialize_timeout: float = 400,
) -> Self:
    # Create multiprocessing channels for bidirectional communication
    ev_send, ev_recv = mp_channel[Event | RunnerTerminationError]()
    task_sender, task_recv = mp_channel[Task]()  # <-- Task channel created
    cancel_sender, cancel_recv = mp_channel[TaskId]()

    # Launch the runner subprocess
    runner_process = AsyncProcess(
        target=entrypoint,
        args=(
            bound_instance,
            ev_send,
            task_recv,  # <-- task_receiver passed to subprocess
            cancel_recv,
            logger,
        ),
        daemon=True,
    )
    # ...
    self = cls(
        # ...
        _task_sender=task_sender,  # Store in supervisor (parent process)
        # ...
    )
    return self
```

**Location:** Lines ~200-245

**Key Details:**
- `mp_channel[Task]()` creates a multiprocessing channel for Task types
- Returns `(task_sender, task_recv)` tuple
- `task_sender` stays in the parent (Worker process)
- `task_recv` passed to subprocess via `entrypoint()` args

### 4.2 Task Transmission Method

```python
async def start_task(self, task: Task):
    if task.task_id in self.pending:
        logger.warning(f"Skipping invalid task {task} as it has already been submitted")
        return
    if task.task_id in self.completed:
        logger.warning(f"Skipping invalid task {task} as it has already been completed")
        return
    
    logger.info(f"Starting task {task}")
    event = anyio.Event()
    self.pending[task.task_id] = event
    self.in_progress[task.task_id] = task
    
    try:
        await self._task_sender.send_async(task)  # <-- TASK SENT HERE
    except ClosedResourceError:
        self.in_progress.pop(task.task_id, None)
        logger.warning(f"Task {task} dropped, runner closed communication.")
        return
    
    await event.wait()  # Wait for TaskAcknowledged
```

**Location:** Lines ~295-320

**Pipeline Step:**
1. Stores task in `pending` dict
2. Sends task via `await self._task_sender.send_async(task)`
3. Waits for `TaskAcknowledged` event from subprocess

---

## 5. Runner Subprocess Bootstrap

**File:** [`/home/bdeeley/exo/src/exo/worker/runner/bootstrap.py`](src/exo/worker/runner/bootstrap.py)

### 5.1 Entrypoint Function (Subprocess Entry)

```python
def entrypoint(
    bound_instance: BoundInstance,
    event_sender: MpSender[Event | RunnerTerminationError],
    task_receiver: MpReceiver[Task],  # <-- Receives the channel
    cancel_receiver: MpReceiver[TaskId],
    _logger: "loguru.Logger",
) -> None:
    global logger
    logger = _logger

    logger.info("🚀 BOOTSTRAP ENTRYPOINT STARTED")
    
    # ... Environment setup, library paths, etc. ...
    
    try:
        # Create the appropriate builder (MLX or Image)
        logger.info("📦 LOADING DEPENDENCIES")
        builder: Builder = ...  # MlxBuilder or MfluxBuilder
        
        # Create the Runner instance with task_receiver
        logger.info("🏃 CREATING RUNNER INSTANCE")
        runner = Runner(bound_instance, builder, event_sender_downcast, task_receiver)
        logger.info("✓ Runner instance created")
        
        # Start the main event loop
        logger.info("🎯 STARTING RUNNER MAIN LOOP")
        runner.main()  # <-- Entry to task processing
        logger.info("✓ Runner main loop completed")
        
    except ClosedResourceError:
        logger.warning("⚠️ Runner communication closed unexpectedly")
    except Exception as e:
        logger.opt(exception=e).warning(f"❌ Runner crashed: {e}")
        event_sender.send(RunnerTerminationError.from_exception(e))
        raise SystemExit(1) from e
    finally:
        logger.info("🏁 SHUTTING DOWN RUNNER")
        try:
            event_sender.close()
            task_receiver.close()
        finally:
            event_sender.join()
            task_receiver.join()
            logger.info("👋 BOOTSTRAP ENTRYPOINT EXITING")
```

**Location:** Lines ~40-180

**Key Points:**
- Receives `task_receiver: MpReceiver[Task]` as subprocess argument
- Creates Runner with task_receiver: `Runner(..., task_receiver)`
- Calls `runner.main()` to start the task processing loop

---

## 6. Runner Task Reception & Processing

**File:** [`/home/bdeeley/exo/src/exo/worker/runner/runner.py`](src/exo/worker/runner/runner.py)

### 6.1 Runner Initialization

```python
class Runner:
    def __init__(
        self,
        bound_instance: BoundInstance,
        builder: Builder,
        event_sender: MpSender[Event],
        task_receiver: MpReceiver[Task],  # <-- Stored here
    ):
        self.event_sender = event_sender
        self.task_receiver = task_receiver  # <-- Saved for use in main()
        # ... other initialization ...
```

**Location:** Lines ~75-110

### 6.2 Task Reader Thread

```python
def _start_task_reader(self) -> None:
    if self._task_reader_thread is not None:
        return

    def loop() -> None:
        try:
            with self.task_receiver:  # <-- Opens the channel
                for task in self.task_receiver:  # <-- Iterates over tasks
                    self._work_queue.put(task)  # <-- Puts each task in queue
        except (EndOfStream, ClosedResourceError):
            pass
        finally:
            self._work_queue.put(_TaskStreamClosed())

    self._task_reader_thread = threading.Thread(target=loop, name="task-reader")
    self._task_reader_thread.start()
```

**Location:** Lines ~155-170

**Task Reception Pipeline:**
1. Opens `task_receiver` channel (with context manager)
2. Blocks awaiting tasks from `_task_sender` in parent process
3. Each received task is put into `_work_queue` (thread-safe queue)
4. Closes cleanly when channel is closed

### 6.3 Main Loop & Task Processing

```python
def main(self):
    self._start_task_reader()  # <-- Start receiving tasks
    try:
        while True:
            try:
                item = self._work_queue.get()  # <-- Get task from queue
                if isinstance(item, _TaskStreamClosed):
                    break
                if isinstance(item, PrefillTask):
                    self._serve_prefill(item)
                    continue
                if item.task_id in self.seen:
                    logger.warning("repeat task - potential error")
                    continue
                
                self.seen.add(item.task_id)
                self.handle_first_task(item)  # <-- Process the task
                
                if isinstance(self.current_status, RunnerShutdown):
                    break
            except Exception as e:
                logger.error(f"Unhandled exception: {e}", exc_info=True)
    finally:
        # Cleanup
        self.task_receiver.close()
        if self._task_reader_thread is not None:
            self._task_reader_thread.join(timeout=5)
```

**Location:** Lines ~208-238

### 6.4 Task Handling (ConnectToGroup Example)

```python
def handle_first_task(self, task: Task):
    self.send_task_status(task.task_id, TaskStatus.Running)

    match task:
        case ConnectToGroup() if isinstance(self.current_status, RunnerIdle):
            assert isinstance(self.generator, Builder)
            logger.info("╔═══════════════════════════════════════════════════════════════╗")
            logger.info("║ CONNECT_TO_GROUP TASK STARTED                              ║")
            logger.info("╚═══════════════════════════════════════════════════════════════╝")
            
            self.update_status(RunnerConnecting())
            self.acknowledge_task(task)  # <-- Send TaskAcknowledged to parent

            # Call distributed backend initialization
            self.generator.connect(self.bound_instance)
            
            self.send_task_status(task.task_id, TaskStatus.Complete)
            self.update_status(RunnerConnected())
```

**Location:** Lines ~240-300

**Task Acknowledgement:**
```python
def acknowledge_task(self, task: Task):
    self.event_sender.send(TaskAcknowledged(task_id=task.task_id))
```

This sends a `TaskAcknowledged` event back to the parent process, which wakes up the waiting `event` in `RunnerSupervisor.start_task()`.

---

## 7. Complete Pipeline Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│ PARENT PROCESS (Worker)                                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  plan_step() [Worker.plan_step]                               │
│      ↓                                                          │
│  plan() [worker/plan.py]  ← Returns Task or None              │
│      ↓                                                          │
│  _start_runner_task(task)                                      │
│      ↓                                                          │
│  RunnerSupervisor.start_task(task)                            │
│      ↓                                                          │
│  await self._task_sender.send_async(task)                     │
│      ↓                                                          │
│      │   ╔════════════════════════════════════════╗            │
│      │   ║  MULTIPROCESSING CHANNEL (mp_channel) ║            │
│      ├───║  Task flows through this pipe        ║            │
│      │   ║  (Pickle-serialized)                 ║            │
│      │   ╚════════════════════════════════════════╝            │
│      │                                                          │
│  await event.wait()  ← Blocks until TaskAcknowledged          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                               ↓
┌─────────────────────────────────────────────────────────────────┐
│ SUBPROCESS (Runner)                                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  entrypoint() [worker/runner/bootstrap.py]                    │
│      ↓                                                          │
│  Runner.__init__(task_receiver=...)                           │
│      ↓                                                          │
│  Runner.main()                                                 │
│      ↓                                                          │
│  _start_task_reader()                                          │
│      ├─ Opens task_receiver channel                            │
│      └─ Iterates: for task in task_receiver                   │
│           ↓                                                     │
│      _work_queue.put(task)  ← Task buffered in queue           │
│           ↓                                                     │
│  Main loop: item = _work_queue.get()                          │
│      ↓                                                          │
│  handle_first_task(item)  ← Process ConnectToGroup, etc.      │
│      ├─ send_task_status(Running)                             │
│      ├─ acknowledge_task()  ← Send TaskAcknowledged via       │
│      │                         event_sender                    │
│      ├─ [Execute task logic]                                  │
│      └─ send_task_status(Complete)                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
                               ↑
        ╔═════════════════════════════════════════╗
        ║ EVENT CHANNEL (event_sender/event_recv) ║
        ║ TaskAcknowledged, TaskStatusUpdated,    ║
        ║ RunnerStatusUpdated flow back to parent ║
        ╚═════════════════════════════════════════╝
```

---

## 8. Task Types and Their Processing

### ConnectToGroup
- **Returned by:** `_init_distributed_backend()`
- **Trigger:** First runner in distributed instance reaches RunnerConnecting state
- **Handler:** `handle_first_task()` → `generator.connect()` → Ring initialization
- **Subprocess Behavior:** Calls `mx.distributed.init()` for ring formation

### LoadModel
- **Returned by:** `_load_model()`
- **Trigger:** All downloads complete, runner is RunnerConnected or RunnerIdle
- **Handler:** `handle_first_task()` → iterates `generator.load()` → builds engine
- **Subprocess Behavior:** Loads model weights onto device

### StartWarmup
- **Returned by:** `_ready_to_warmup()`
- **Trigger:** Model loaded, coordinating rank readiness
- **Handler:** `handle_first_task()` → `generator.warmup()`
- **Subprocess Behavior:** Pre-loads engine, starts prefill server

### TextGeneration / ImageGeneration / ImageEdits
- **Returned by:** `_pending_tasks()`
- **Trigger:** Task in Pending/Running state and runner is RunnerReady
- **Handler:** `handle_generation_tasks()` → `generator.submit()` → `generator.step()`
- **Subprocess Behavior:** Executes inference, yields chunks

### CreateRunner
- **Returned by:** `_create_runner()`
- **Trigger:** New instance needs a runner on this node
- **Handler:** `plan_step()` → `_create_supervisor()` → Creates RunnerSupervisor
- **Subprocess Behavior:** N/A - handled by parent process

### DownloadModel
- **Returned by:** `_model_needs_download()`
- **Trigger:** Model not yet available
- **Handler:** `plan_step()` → `download_command_sender.send()`
- **Subprocess Behavior:** N/A - handled by download coordinator

### Shutdown
- **Returned by:** `_kill_runner()`
- **Trigger:** Instance no longer exists
- **Handler:** `plan_step()` → `runner.start_task()` → `generator.close()`
- **Subprocess Behavior:** Cleanup and exit

---

## 9. Key Files Summary

| File | Purpose | Key Function |
|------|---------|--------------|
| `src/exo/worker/plan.py` | Task planning logic | `plan()` |
| `src/exo/worker/main.py` | Worker orchestration | `plan_step()`, `_start_runner_task()` |
| `src/exo/worker/runner/supervisor.py` | Runner subprocess management | `start_task()`, mp_channel setup |
| `src/exo/worker/runner/bootstrap.py` | Subprocess entry point | `entrypoint()` |
| `src/exo/worker/runner/runner.py` | Task reception and processing | `main()`, `handle_first_task()` |

---

## 10. Common Issues & Debugging

### Task Never Reaches Subprocess
**Check:**
1. `plan()` returning None? Add logging to plan_step
2. `_start_runner_task()` not called? Check task type matching in plan_step
3. RunnerSupervisor channel closed? Check supervisor logs

### Task Acknowledged But Not Processed
**Check:**
1. Is `_task_reader_thread` started? Check `_start_task_reader()` was called
2. Is task in work queue? Check task_receiver iteration
3. Is handle_first_task() matching the task type?

### Subprocess Receiving Wrong Task Type
**Check:**
1. Are channels using same Task type annotations?
2. Is task serialization working? (MP uses pickle)
3. Check task.task_id uniqueness

### ConnectToGroup Timeout
**Check:**
1. All expected runners reached RunnerConnecting state?
2. Ring initialization hang in `generator.connect()`?
3. Network connectivity between nodes?

