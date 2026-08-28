# Qwen3.8-27B · RTX 5090 · SGLang

A single-GPU serving recipe for [Qwen3.8-27B](https://huggingface.co/gittensor-model-hub/Qwen3.8-27B-NVFP4-RTX5090-LMHead4) (NVFP4 W4A4, `lm_head` included in the 4-bit quantization) on an RTX 5090 (32 GiB), served by [SGLang](https://github.com/sgl-project/sglang) in Docker with the [gittensor DSpark NVFP4](https://huggingface.co/gittensor-model-hub/Qwen3.8-27B-DSpark-NVFP4) speculative drafter: 192K-token context, fp8 KV cache, FlashInfer attention on Blackwell (SM120). One idempotent command takes a machine from zero to a serving model.

```powershell
.\scripts\bootstrap.ps1   # zero-to-ready: Docker Desktop (installs if missing) → HF auth → weights → image → server up on 127.0.0.1:8080
```

A llama.cpp serving recipe for the same model and GPU lives in the separate repository [vikesh-c/Qwen-3.8-27B-RTX-5090](https://github.com/vikesh-c/Qwen-3.8-27B-RTX-5090).

## Config

| | |
|---|---|
| Model | `gittensor-model-hub/Qwen3.8-27B-NVFP4-RTX5090-LMHead4` (NVFP4 W4A4 incl. `lm_head`, ~17.1 GB in VRAM; every non-`lm_head` tensor is bit-identical to the parent NVFP4 release) |
| Speculative decoding | gittensor DSpark-NVFP4 draft (served `modelopt_fp4`), 1 step, topk 1, 8 draft tokens |
| Context | 196,608 tokens, fp8_e4m3 KV cache (~217,130-token pool), chunked prefill 2048 |
| Attention backend | FlashInfer |
| Serving | `lmsysorg/sglang:qwen38-27b` Docker image, digest-pinned, `--language-only`, `--ipc=host`, `--mem-fraction-static 0.95`, 1 concurrent request, radix cache disabled |
| Queueing | One active request; `--max-queued-requests` and `--max-total-tokens` omitted, so waiting requests are unbounded and the KV pool is auto-sized; FCFS policy |
| Timeouts | `SGLANG_REQ_WAITING_TIMEOUT=-1` and `SGLANG_REQ_RUNNING_TIMEOUT=-1` (no SGLang queue/running timeout) |
| Idle behavior | `--sleep-on-idle` parks the scheduler while the endpoint is idle instead of busy-polling a CPU core |
| API | authenticated loopback `127.0.0.1:8080`; key auto-created once under `%LOCALAPPDATA%\Qwen3.8-27B-RTX-5090-SGLang\sglang.key`, protected ACL, reused forever |
| VRAM budget | target weights ~17.1 GB + draft weights ~1.3 GB + main KV ~6.6 GB + draft KV ~1.5 GB + workspace ~4.5 GB ≈ 31.0 GiB of 32 GiB |

### Why this target + this drafter

- **LMHead4 target** — the parent NVFP4 release left the 248,320×5,120 output head in BF16, which is 2.54 GB re-read on every decoded token. The LMHead4 release quantizes only that head to NVFP4 (all other tensors bit-identical), cutting it to 0.72 GB. On this GPU decode is weight-bandwidth bound, so those saved bytes convert nearly 1:1 into tokens/s — measured +12–24% decode versus the parent at 4K–32K contexts, and ~1.8 GB freed VRAM that becomes KV pool (166K → 217K tokens at the same memory fraction).
- **gittensor DSpark-NVFP4 drafter** — 1.30 GB (vs 2.72 GB for the BF16/FP8 RadixArk draft), NVFP4-quantized MLP and attention-output projections with precision-sensitive projections kept in BF16, trained against this target family for a ~2.9 mean accepted tokens per step. Served with `--speculative-draft-model-quantization modelopt_fp4`.
- **One required local transform** — the upstream draft config declares `dtype: float16`, but SGLang's DSpark projector feeds BF16 target hidden states into the draft's `fc` projection, which crashes on the first speculative decode (`RuntimeError: expected mat1 and mat2 to have the same dtype, but got: c10::BFloat16 != c10::Half`). `bootstrap.ps1` therefore downloads the pinned upstream revision and writes a serving copy whose `config.json` sets `dtype: "bfloat16"` — weights stay byte-identical to upstream.

## Performance (RTX 5090)

Measured with [llama-benchy](https://github.com/eugr/llama-benchy) 0.4.0 — an engine-agnostic endpoint benchmark (pp = prompt processing, tg = token generation) run against this OpenAI-compatible server. Unique real book text per request, no prefix-cache reuse, 3 runs per context (reported as the mean ± std), exactly 2,048 generated tokens, single stream.

**Prefill** (cold, unique prompts, 3 runs per context, mean ± std):

| Context | tok/s | Std | Time to first token |
|---:|---:|---:|---:|
| 4,096 | 10,451.9 | 326.5 | 0.4 s |
| 8,192 | 11,162.2 | 133.0 | 0.7 s |
| 16,384 | 10,284.8 | 341.9 | 1.6 s |
| 32,768 | 8,465.3 | 52.3 | 3.9 s |
| 65,536 | 6,203.6 | 12.9 | 10.6 s |
| 131,072 | 3,977.2 | 19.1 | 33.0 s |

**Decode** (2,048 exact tokens, mean ± std, DSpark acceptance workload-sensitive):

| Context | tok/s | Std |
|---:|---:|---:|
| 4,096 | 181.9 | 40.3 |
| 8,192 | 153.0 | 38.4 |
| 16,384 | 188.7 | 29.2 |
| 32,768 | 151.6 | 9.2 |
| 65,536 | 129.0 | 2.5 |
| 131,072 | 123.4 | 7.8 |

Versus the previous stack (parent NVFP4 target with BF16 `lm_head`, RadixArk FP8 draft, 163,840 context — [`results/qwen3.8-27b-rtx5090-sglang-dspark-3x2048.md`](results/qwen3.8-27b-rtx5090-sglang-dspark-3x2048.md)): decode is +12.5% at 4,096, +24.4% at 16,384, +20.0% at 32,768, and +20.3% at 131,072 (the 8K and 65K rungs land within the run-to-run std bands of the earlier receipt); prefill is +3–5% at every rung above 8K; and the KV pool grows from ~166,466 to ~217,130 tokens at the same memory fraction, which is what funds the 196,608-token context window.

Full JSON receipts: [`results/`](results/). The ladder tops out at 131,072 (128k) prompt tokens with 3 runs per rung, each an exact 2,048-token completion. The server admits prompts up to ~194,560 tokens (196,608 minus a 2,048-token completion).

## Benchmarking

`.\benchmarks\bench.ps1` runs the six-rung ladder (top rung 131,072 / 128k) in a single llama-benchy invocation, 3 runs per rung. Each request reports both the cold-prefill rate and the post-prefill decode rate for the same context shape, so each ladder yields both tables:

```powershell
.\benchmarks\bench.ps1   # writes results\qwen3.8-27b-rtx5090-sglang-lmhead4-dspark-nvfp4-3x2048.{json,md}
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
- **Hugging Face auth is required** for the ~19 GB model + draft download — bootstrap detects the `hf` CLI, installs it if missing, and walks you through login before downloading. Both repositories are public; a token just avoids anonymous rate limits.
- The Docker image is pulled by digest, so a fresh pull reproduces the exact tested build.
- Rollback/second model: stop, point `config/profile.json` at another image/model pair, start. One model at a time.

## License

MIT for repository material. Model weights, draft weights, the SGLang image, and llama-benchy retain upstream terms; this repo does not redistribute them.
