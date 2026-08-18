# Qwen3.8-27B · RTX 5090 · SGLang

A single-GPU serving recipe for [Qwen3.8-27B](https://huggingface.co/gittensor-model-hub/Qwen3.8-27B-NVFP4-RTX5090) (NVFP4 W4A4) on an RTX 5090 (32 GiB), served by [SGLang](https://github.com/sgl-project/sglang) in Docker with [RadixArk DSpark](https://huggingface.co/RadixArk/Qwen3.8-27B-DSpark) speculative decoding: 160K-token context, fp8 KV cache, FlashInfer attention on Blackwell (SM120). One idempotent command takes a machine from zero to a serving model.

```powershell
.\scripts\bootstrap.ps1   # zero-to-ready: Docker Desktop (installs if missing) → HF auth → weights → image → server up on 127.0.0.1:8080
```

A llama.cpp serving recipe for the same model and GPU lives in the separate repository [vikesh-c/Qwen-3.8-27B-RTX-5090](https://github.com/vikesh-c/Qwen-3.8-27B-RTX-5090).

## Config

| | |
|---|---|
| Model | `gittensor-model-hub/Qwen3.8-27B-NVFP4-RTX5090` (NVFP4 W4A4, ~18.8 GB weights) |
| Speculative decoding | RadixArk DSpark draft (served fp8), 7 steps, topk 1, 8 draft tokens |
| Context | 163,840 tokens, fp8_e4m3 KV cache (~166,466-token pool), chunked prefill 2048 |
| Attention backend | FlashInfer |
| Serving | `lmsysorg/sglang:qwen38-27b` Docker image, digest-pinned, `--language-only`, `--mem-fraction-static 0.95`, 1 concurrent request, radix cache disabled |
| Queueing | One active request; `--max-queued-requests` and `--max-total-tokens` omitted, so waiting requests are unbounded and the KV pool is auto-sized; FCFS policy |
| Timeouts | `SGLANG_REQ_WAITING_TIMEOUT=-1` and `SGLANG_REQ_RUNNING_TIMEOUT=-1` (no SGLang queue/running timeout) |
| Idle behavior | `--sleep-on-idle` parks the scheduler while the endpoint is idle instead of busy-polling a CPU core |
| API | authenticated loopback `127.0.0.1:8080`; key auto-created once under `%LOCALAPPDATA%\Qwen3.8-27B-RTX-5090-SGLang\sglang.key`, protected ACL, reused forever |
| VRAM budget | weights ~18.8 GB + main KV ~5.1 GB + draft KV ~1.6 GB + draft weights ~1.4 GB + workspace ~4.4 GB ≈ 31.3 GiB of 32 GiB |

## Performance (RTX 5090)

Measured with [llama-benchy](https://github.com/eugr/llama-benchy) 0.4.0 — an engine-agnostic endpoint benchmark (pp = prompt processing, tg = token generation) run against this OpenAI-compatible server. Unique real book text per request, no prefix-cache reuse, 3 runs per context (reported as the mean ± std), exactly 2,048 generated tokens, single stream.

**Prefill** (cold, unique prompts, 3 runs per context, mean ± std):

| Context | tok/s | Std | Time to first token |
|---:|---:|---:|---:|
| 4,096 | 10,626.7 | 134.4 | 0.4 s |
| 8,192 | 10,663.8 | 67.9 | 0.8 s |
| 16,384 | 9,914.1 | 48.0 | 1.7 s |
| 32,768 | 8,185.5 | 1.9 | 4.0 s |
| 65,536 | 5,999.6 | 4.8 | 10.9 s |
| 131,072 | 3,825.9 | 30.9 | 34.3 s |

**Decode** (2,048 exact tokens, mean ± std, DSpark acceptance workload-sensitive):

| Context | tok/s | Std |
|---:|---:|---:|
| 4,096 | 161.7 | 8.2 |
| 8,192 | 162.4 | 11.1 |
| 16,384 | 151.7 | 17.1 |
| 32,768 | 126.3 | 22.6 |
| 65,536 | 129.4 | 5.2 |
| 131,072 | 102.6 | 13.2 |

Full JSON receipts: [`results/`](results/). The ladder tops out at 131,072 (128k) prompt tokens with 3 runs per rung, each an exact 2,048-token completion.

## Benchmarking

`.\benchmarks\bench.ps1` runs the six-rung ladder (top rung 131,072 / 128k) in a single llama-benchy invocation, 3 runs per rung. Each request reports both the cold-prefill rate and the post-prefill decode rate for the same context shape, so each ladder yields both tables:

```powershell
.\benchmarks\bench.ps1   # writes results\qwen3.8-27b-rtx5090-sglang-dspark-3x2048.{json,md}
```

`.\benchmarks\install-llama-benchy.ps1` installs the benchmark tool (via `uvx`, pinned to llama-benchy 0.4.0) if it is not already available.

One SGLang-specific flag is passed for you: `--extra-body return_token_ids=false`. This image rejects that field in streaming requests (HTTP 400), and llama-benchy sends it by default; disabling it switches token counting to the response usage block.

## Repository map

```
scripts/    bootstrap, start, stop, status, probe, validate
benchmarks/ bench (combined prefill+decode ladder), install-llama-benchy
results/    measured receipts (JSON + summary)
config/     profile templates (copy → profile.json)
tests/      result-parser regression test
```

## Install notes

- **Windows-side Docker Desktop is required** (GPU support is built in). `bootstrap.ps1` installs Docker Desktop via winget if it is missing, starts the engine if it is stopped, and verifies `nvidia-smi` — no WSL-side tooling or Linux GPU toolkit needed. Everything is idempotent: re-running picks up where the machine already is.
- **Hugging Face auth is required** for the ~20 GB model + draft download — bootstrap detects the `hf` CLI, installs it if missing, and walks you through login before downloading. Both repositories are public; a token just avoids anonymous rate limits.
- The Docker image is pulled by digest, so a fresh pull reproduces the exact tested build.
- Rollback/second model: stop, point `config/profile.json` at another image/model pair, start. One model at a time.

## License

MIT for repository material. Model weights, draft weights, the SGLang image, and llama-benchy retain upstream terms; this repo does not redistribute them.
