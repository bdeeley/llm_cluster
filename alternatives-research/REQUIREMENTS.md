# Cluster Requirements for LLM Inference Alternative

## Hardware
- 3 nodes: maxpower (48GB VRAM total), theplague (12GB RTX 3060)
- Total: 60GB distributed VRAM
- Linux (Ubuntu 22.04, Debian 12)
- NVIDIA CUDA 12.4
- libp2p-based discovery (optional, can use static peers)

## Functional Requirements
1. **Model Distribution**: Distribute large models across nodes with tensor/pipeline sharding
2. **Inference**: OpenAI-compatible `/v1/chat/completions` API
3. **Model Support**: MLX community models (4B-72B quantized)
4. **State Management**: Runners must actually spawn processes and consume VRAM
5. **Reliability**: No state machine lies (if runner says "Ready", it must be running)

## Current Blocker in exo
- Runner state machine reports "RunnerReady" but ZERO processes spawned
- VRAM never consumed (0 MB on 60GB pool)
- Inference hangs indefinitely
- Root cause: subprocess/actor model broken

## Success Criteria
1. Model loads → VRAM increases across nodes
2. Inference works → `/v1/chat/completions` returns tokens
3. Performance → visible GPU utilization via nvidia-smi pmon
4. Stability → no state/reality mismatch

