# Ollama Benchmark — qwen2.5-coder-32b Q4_K_M

**Date:** 2026-05-23  
**Host:** maxpower (Debian 13 trixie)  
**CPUs:** 2× Xeon Gold 6234 (32 threads)  
**RAM:** 157 GB  
**Driver:** NVIDIA 550.163.01 / CUDA 12.4  
**Ollama:** 0.23.2  

## Hardware

| GPU | VRAM | Compute | PCIe |
|-----|------|---------|------|
| NVIDIA GeForce RTX 3060 | 12 GB | sm_8.6 | 5B:00.0 |
| Quadro P6000 | 24 GB | sm_6.1 | 9E:00.0 |
| **Total** | **36 GB** | | |

## Model

| | |
|---|---|
| Model | `qwen2.5-coder32b-cline:latest` (Qwen2.5-Coder-32B-Instruct) |
| Quantization | Q4_K_M |
| Layers | 65 total — **all 65 on GPU** (RTX 3060: 15, P6000: 50) |
| Context | 32768 tokens |
| KV cache | q8_0 + flash attention |
| VRAM used | ~7.2 GB (3060) + ~18.3 GB (P6000) = **25.5 GB** |

## Results

| metric | speed |
|---|---|
| pp512 — prompt processing (cold) | **~237 t/s** |
| tg128 — token generation | **12.83 t/s** |

_3 runs each, temperature=0. pp cold = first run before prompt cache warms._

## Comparison — tg128 (tok/s), Qwen2.5-32B Q4_K_M

| hardware | tg (t/s) |
|---|---|
| 2× RTX 3090 48 GB | ~15–18 |
| Mac Studio M3 Ultra 192 GB | ~15–18 |
| RTX 4090 24 GB (single) | ~13–15 |
| **RTX 3060 12 GB + P6000 24 GB** | **12.83** |
| Mac Studio M2 Ultra 192 GB | ~10–12 |

## Notes

- Default Ollama VRAM estimation left **8 layers on CPU**, causing 1600% CPU load and ~9 GB RSS.  
  Fixed by adding `PARAMETER num_gpu 99` to the Modelfile, which forces all layers to GPU.
- RTX 3060 power limit raised from 170 W → 187 W (resets on reboot; not yet persisted).
- P6000 does the heavy lifting; RTX 3060 handles the overflow layers.
