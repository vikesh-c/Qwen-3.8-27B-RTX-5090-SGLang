# Qwen3.8-27B - RTX 5090 - SGLang -- llama-benchy ladder

- llama-benchy 0.4.0 (2026-08-28 07:52:40Z), latency 1.9 ms
- Model: `qwen3.8-27b` on SGLang (context 196608, KV dtype fp8_e4m3, fp8 KV, FlashInfer, DSpark spec: NVFP4 draft via modelopt_fp4)
- Workload: unique real book text, no prefix-cache reuse, 3 runs x 2048 exact output tokens, temperature 0, single stream, per context: 4096, 8192, 16384, 32768, 65536, 131072
- GPU: NVIDIA GeForce RTX 5090 (32607 MiB total)

## Results

**Prefill** (cold, unique prompts -- mean of the measured runs):

| Context | tok/s | Std | Time to first token |
|---:|---:|---:|---:|
| 4,096 | 10451.9 | 326.5 | 0.4 s |
| 8,192 | 11162.2 | 133.0 | 0.7 s |
| 16,384 | 10284.8 | 341.9 | 1.6 s |
| 32,768 | 8465.3 | 52.3 | 3.9 s |
| 65,536 | 6203.6 | 12.9 | 10.6 s |
| 131,072 | 3977.2 | 19.1 | 33.0 s |

**Decode** (exact output length, DSpark acceptance workload-sensitive):

| Context | tok/s | Std |
|---:|---:|---:|
| 4,096 | 181.9 | 40.3 |
| 8,192 | 153.0 | 38.4 |
| 16,384 | 188.7 | 29.2 |
| 32,768 | 151.6 | 9.2 |
| 65,536 | 129.0 | 2.5 |
| 131,072 | 123.4 | 7.8 |

Raw per-run distribution: [qwen3.8-27b-rtx5090-sglang-lmhead4-dspark-nvfp4-3x2048.json](qwen3.8-27b-rtx5090-sglang-lmhead4-dspark-nvfp4-3x2048.json)
