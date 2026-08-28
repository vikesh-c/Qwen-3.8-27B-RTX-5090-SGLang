# Security notes

- The launcher creates a random one-line API key under `%LOCALAPPDATA%\Qwen3.8-27B-RTX-5090-SGLang` and applies a protected user/SYSTEM/Administrators ACL. If `SGLANG_API_KEY_FILE` is overridden, keep it outside the repository and protect it equivalently.
- The default and only directly supported bind address is the Docker loopback port mapping to `127.0.0.1`. An API key over plain HTTP is not transport encryption; use an authenticated encrypted tunnel or TLS proxy for deliberate remote access.
- The lifecycle scripts identify the exact container name before stopping it. They never stop unrelated containers or delete model/runtime data.
- Do not commit model weights, Docker images, API keys, local profiles, slot state, prompt caches, raw logs, prompt transcripts, or machine-specific paths.
- Bootstrap pins model revisions and the Docker image digest. Review any revision, hash, or digest change before downloading replacement bytes.
- The draft model is downloaded from its pinned upstream revision, then served from a local copy whose `config.json` sets `"dtype": "bfloat16"` (upstream ships `float16`, which crashes SGLang's DSpark projector on the first speculative decode). Weight files are byte-identical to upstream; bootstrap re-derives the copy on every run, so any upstream config change other than the dtype would still be visible.
- If a credential is committed, revoke it immediately and remove it from repository history.

Report vulnerabilities privately through GitHub's security channel or directly to the repository owner. Do not publish credentials or exploit details in a public issue.
