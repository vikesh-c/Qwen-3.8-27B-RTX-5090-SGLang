# Measured results

Benchmark receipts live here as JSON + Markdown pairs. The JSON is the raw
llama-benchy output (full per-run distribution); the Markdown is the parsed
prefill + decode tables.

Receipt naming: `qwen3.8-27b-rtx5090-sglang-<variant>-<runs>x<output>.{json,md}`.

- `<variant>` — the served stack (`dspark` = RadixArk fp8 draft era;
  `lmhead4-dspark-nvfp4` = the current LMHead4 + NVFP4 draft stack).
- `<runs>` — independent runs per context (3 in the default ladder).
- `<output>` — exact generated tokens per run (2,048 in the default ladder).

- `qwen3.8-27b-rtx5090-sglang-lmhead4-dspark-nvfp4-3x2048.{json,md}` —
  **canonical ladder for the current recipe**, recorded 2026-08-28 on the
  RTX 5090 (lmsysorg/sglang:qwen38-27b @ febfb971, Qwen3.8-27B-NVFP4-RTX5090-LMHead4
  target @ e60a41d4, gittensor DSpark-NVFP4 draft @ eba1ac5a served via
  modelopt_fp4, fp8_e4m3 KV, FlashInfer, 196,608 context, ~217,130-token KV pool):
  6 context rungs (top 131,072 / 128k), 3 runs x 2,048 tokens per rung, temp 0,
  unique real book text, no prefix-cache reuse. Decode: 181.9 tok/s at 4,096
  rising to 188.7 at 16,384, 123.4 at 131,072.

- `qwen3.8-27b-rtx5090-sglang-dspark-3x2048.{json,md}` — earlier-era ladder
  (2026-08-18): same image, parent NVFP4 target with BF16 lm_head, RadixArk
  DSpark fp8 draft, 163,840 context. Kept for comparison; see the README
  performance table for the head-to-head.

The JSON receipts record the llama-benchy version, timestamp, latency mode,
advertised model, and every per-run value so a number in the Markdown is always
traceable to a measurement, not an average of unknown provenance.

Reproduce with `.\benchmarks\bench.ps1` against the running server.
