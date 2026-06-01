# exo Cluster Investigation

## 2026-05-25

### Goal

Get real distributed inference working across all three exo nodes:

- maxpower primary: `12D3KooWRVFf15nsjzqWTSzfTCpTi9N41jg36PnZvEpA6Gsi9rsJ`
- maxpower worker: `12D3KooWDozLbsrtUMh6uHKyZSyP8544aN8EXRDWVMKEmny6izay`
- theplague remote: `12D3KooWPyCoA1ztta1GAX77g8FAniue6kxyn4QjLrARsFsUA93e`

Target model:

- `mlx-community/Llama-3.3-70B-Instruct-4bit`
- `sharding=Pipeline`
- `instance_meta=MlxRing`

### What Was Fixed

1. Pascal runtime JIT compatibility in local MLX CUDA sources.
   - Replaced raw `__grid_constant__` usage with `MLX_GRID_CONSTANT` gated on `__CUDA_ARCH__ >= 700`.
   - Patched gather, scatter, gather-axis, scatter-axis, slice-update, and generated compiled-kernel source emission.

2. Mixed local GPU JIT cache collisions.
   - Root cause: the two local GPUs share one on-disk MLX JIT cache but use different architectures (`sm_61` and `sm_86`).
   - Fix: in `jit_module.cpp`, the cache key now includes the effective target architecture, so Pascal and Ampere no longer reuse the same compiled gather PTX/cubin entry.

3. Local MLX rebuild flow.
   - Build script: `/tmp/build-mlx.sh`
   - Parallelism is configurable with `BUILD_JOBS`.
   - Current build log path: `/tmp/mlx-build-local.log`

### Verified Working State

Local rebuild artifact:

- `/tmp/mlx-wheels/mlx-0.32.0-cp313-cp313-linux_x86_64.whl`

Local reinstall + cache reset:

- Reinstalled with `uv pip --python /home/bdeeley/exo/.venv/bin/python --force-reinstall ...`
- Cleared `/tmp/mlx/0.32.0/ptx`

Cheap discriminating validation:

- Fresh shared cache
- Sequential `mx.take(...)` gather on both local GPUs in one process
- Result:
  - RTX 3060 (`sm_86`): pass
  - Quadro P6000 (`sm_61`): pass

Cluster validation:

- Restarted `exo.service` and `exo-worker.service`
- Reformed full three-node topology
- Fresh placement accepted on `http://127.0.0.1:52415/place_instance`
- All three runners progressed through `RunnerLoading` into `RunnerWarmingUp`
- End-to-end OpenAI-compatible chat request succeeded on `POST /v1/chat/completions`

Observed successful completion:

> `I am fully operational now`

This is the first verified end-to-end passing run after the MLX Pascal JIT fix plus the architecture-specific JIT cache-key fix.

### Notes From This Host

Direct MLX repros on Debian need the distro CUDA layout exposed explicitly:

- `CUDA_HOME=/usr`
- `CUDA_PATH=/usr`
- `CPATH=/usr/include:/usr/lib/cuda/include`
- `LD_LIBRARY_PATH` must include the venv NVIDIA user-space libraries

Without that environment, the repro can fail before reaching the real JIT-cache behavior.

### Remaining Risks

1. Election churn still appears during local service restarts and demotion.
   - The local primary and worker still show election/demotion chatter before converging on theplague as master.

2. Restart noise is still ugly.
   - Local journals still show PyO3 interpreter assertions and Hypercorn/AnyIO cancellation noise during shutdown/restart of the replaced processes.
   - This did not block the successful three-node inference run, but it is still worth cleaning up.

### Current Conclusion

Real three-node distributed inference is now working on this cluster with the patched local MLX wheel.
The original Pascal `no kernel image` / compiled gather failures are no longer the blocking issue.

## 2026-05-26

### Goal

Move from the earlier 3-node smoke-tested state to a real 4-node cluster that is usable for Cline-sized prompts:

- maxpower primary (Quadro P6000, 24 GB): `12D3KooWRVFf15nsjzqWTSzfTCpTi9N41jg36PnZvEpA6Gsi9rsJ`
- maxpower worker (RTX 3060, 12 GB): `12D3KooWDozLbsrtUMh6uHKyZSyP8544aN8EXRDWVMKEmny6izay`
- theplague remote (RTX 3060, 12 GB): `12D3KooWPyCoA1ztta1GAX77g8FAniue6kxyn4QjLrARsFsUA93e`
- debian remote (RTX 3090, 24 GB): `12D3KooWKTVqUQL4jDvPJ5hWuCxdH25uFWsZNH8t3uaapHUS3Rxn`

Target model:

- `mlx-community/Qwen3.6-27B-6bit`
- primary serving mode under test: `Pipeline` + `MlxRing`
- higher-parallelism mode under investigation: `Tensor` + `MlxRing`

### What Was Verified

1. Exact 4-node placement works when the instance is created from `/instance/previews` and posted back to `/instance`.
   - Minimal real inference succeeded earlier on the 4-node ring with a short prompt.
   - All four runners can load, warm up, and reach `RunnerReady` for `mlx-community/Qwen3.6-27B-6bit`.

2. Shared storage and launcher layout were cleaned up enough for repeatable 4-node restarts.
   - Local model directories are split per node under `/BIGMIRROR` to avoid concurrent corruption.
   - Remotes launch from `/home/bdeeley/exo/go` and log to `/BIGMIRROR/exo-remotes.log`.

3. The large-prompt failure mode is now understood much better.
   - A Cline request that looked logically tiny (`make a hello world bash script`) still serialized into a very large prompt.
   - With the original 4-node memory weighting (`12/24/12/24`), that prompt spent a long time in prefill and eventually failed with `cudaMallocAsync(... ) failed: out of memory`.

### Findings

1. Pipeline fit is not the same thing as single-request parallelism.
   - In 4-node `Pipeline` mode the model fits, but one stage can dominate compute during prefill while the other ranks mostly wait.
   - This matched live observation: VRAM was resident on all cards, but the Quadro carried most of the sustained compute and the links showed little activity.

2. The 12 GB cards were the prompt-headroom limiter, not total cluster VRAM.
   - The cluster had enough aggregate memory to hold weights.
   - The failure came from per-shard prompt/KV-cache pressure during long prefill on the smallest shards.

3. Reweighting the advertised memory changed the layer split in the expected direction.
   - Original practical weighting behaved like `12/24/12/24`, producing a 4-way pipeline split that still left the 12 GB cards too full for Cline-like prompts.
   - Tuning both 12 GB nodes to `OVERRIDE_MEMORY_MB=8000` while leaving both 24 GB nodes at `24000` changed the 4-node preview to an `8 / 8 / 24 / 24` layer split.

4. That pipeline rebalance materially improved memory headroom.
   - Before the rebalance, the 12 GB cards were typically near `11-12 GB` residency once the model and prompt pressure landed.
   - After the `8 / 8 / 24 / 24` rebalance, the two 12 GB cards were closer to `~5 GB` steady-state residency after warmup.
   - This is a real cluster-side improvement, but it does not change the basic single-request behavior of pipeline execution.

5. 4-node tensor parallelism is available for this model on the live cluster.
   - `/instance/previews` exposed a valid 4-node `Tensor` + `MlxRing` placement for `mlx-community/Qwen3.6-27B-6bit`.
   - The active instance structure for that placement used `TensorShardMetadata` on all four ranks.
   - This is the correct direction if the goal is stronger simultaneous GPU participation and real inter-node traffic on one request.

### Operational Problems Hit During This Work

1. Restart churn was dominated by stale process state, not by placement logic.
   - Killing only `uv run exo` wrappers was insufficient; the child `.../.venv/bin/exo` daemons also had to be killed.
   - Stale pidfiles such as `/home/bdeeley/.cache/exo/exo.pid` and `/tmp/exo-worker/exo/exo.pid` caused false "daemon already running" failures and split-brain restarts.

2. Topology needed clean restarts before placement previews were trustworthy.
   - During broken restart windows, `/instance/previews` temporarily collapsed to 1-node cycles even though all four node IDs later reappeared in `/state`.

3. The recurring vision warning is still present but was not the text-serving blocker.
   - The runners continue to log `ModuleNotFoundError: No module named 'torch'` while disabling vision weights.
   - Text model load and warmup still complete successfully afterward.

### Current Status

- 4-node `Pipeline` mode can be brought up reliably enough to load and warm up the model.
- The `8 / 8 / 24 / 24` rebalance improves prompt headroom on the 12 GB nodes.
- That rebalance does not solve the user's core complaint about low parallel activity on a single request, because `Pipeline` mode still behaves like a staged execution path.
- 4-node `Tensor` mode is available and is the next meaningful path for higher parallelism, but a clean end-to-end tensor request validation is still pending after restart churn.

### Current Conclusion

The next tuning step should not be more small pipeline reweighting.
If the objective is "more GPUs doing real work at the same time" for one prompt, the cluster needs to be validated in 4-node `Tensor` mode rather than staying in `Pipeline` mode and expecting very different execution behavior.