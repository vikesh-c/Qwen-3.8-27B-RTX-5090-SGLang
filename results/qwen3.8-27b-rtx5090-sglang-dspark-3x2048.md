# Qwen3.8-27B - RTX 5090 - SGLang -- llama-benchy ladder

- llama-benchy 0.4.0 (2026-08-18 11:10:58Z), latency 1.6 ms
- Model: `qwen3.8-27b` on SGLang (context 163840, KV dtype fp8_e4m3, fp8 KV, FlashInfer, DSpark spec)
- Workload: unique real book text, no prefix-cache reuse, 3 runs x 2048 exact output tokens, temperature 0, single stream, per context: 4096, 8192, 16384, 32768, 65536, 131072
- GPU: NVIDIA GeForce RTX 5090 (32607 MiB total)

## Results

**Prefill** (cold, unique prompts -- mean of the measured runs):

| Context | tok/s | Std | Time to first token |
|---:|---:|---:|---:|
| 4,096 | 10,626.7 | 134.4 | 0.4 s |
| 8,192 | 10,663.8 | 67.9 | 0.8 s |
| 16,384 | 9,914.1 | 48.0 | 1.7 s |
| 32,768 | 8,185.5 | 1.9 | 4.0 s |
| 65,536 | 5,999.6 | 4.8 | 10.9 s |
| 131,072 | 3,825.9 | 30.9 | 34.3 s |

**Decode** (exact output length, DSpark acceptance workload-sensitive):

| Context | tok/s | Std |
|---:|---:|---:|
| 4,096 | 161.7 | 8.2 |
| 8,192 | 162.4 | 11.1 |
| 16,384 | 151.7 | 17.1 |
| 32,768 | 126.3 | 22.6 |
| 65,536 | 129.4 | 5.2 |
| 131,072 | 102.6 | 13.2 |

Raw per-run distribution: [qwen3.8-27b-rtx5090-sglang-dspark-3x2048.json](qwen3.8-27b-rtx5090-sglang-dspark-3x2048.json)