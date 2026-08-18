# Measured receipts

Benchmark receipts live here as JSON + Markdown pairs. The JSON is the raw
llama-benchy output (full per-run distribution); the Markdown is the parsed
prefill + decode tables.

Receipt naming: `qwen3.8-27b-rtx5090-sglang-dspark-<runs>x<output>.{json,md}`.

- `<runs>` — independent runs per context (3 in the default ladder).
- `<output>` — exact generated tokens per run (2,048 in the default ladder).

- `qwen3.8-27b-rtx5090-sglang-dspark-3x2048.{json,md}` — canonical ladder, recorded 2026-08-18 on the RTX 5090 (lmsysorg/sglang:qwen38-27b @ febfb971, fp8_e4m3 KV, FlashInfer, DSpark 7/1/8, 163,840 context): 6 context rungs (top 131,072 / 128k), 3 runs x 2,048 tokens per rung, temp 0, unique real book text, no prefix-cache reuse.

The JSON receipt records the llama-benchy version, timestamp, latency mode,
advertised model, and every per-run value so a number in the Markdown is always
traceable to a measurement, not an average of unknown provenance.

Reproduce with `.\benchmarks\bench.ps1` against the running server.
