# bench.ps1 -- combined prefill + decode ladder via llama-benchy.
#
#   .\benchmarks\bench.ps1                          # full 6-rung ladder, 3 runs
#   .\benchmarks\bench.ps1 -Contexts 4096,65536     # subset of rungs
#
# One llama-benchy invocation per rung set. Each request reports BOTH the
# cold-prefill rate (prompt tokens / TTFT) and the post-prefill decode rate
# (output tokens / time-after-first-token) for the same context shape, so a
# single ladder yields both tables -- the "two birds" in one stone.
#
# Workload contract:
#   - contexts: 4096, 8192, 16384, 32768, 65536, 131072
#     (top rung is 131,072 = 128k; the 160k rung is deliberately not run)
#   - exactly $Runs (3) runs per rung, reported as the mean
#   - exactly $OutputTokens (2,048) generated tokens per run (--exact-tg:
#     min_tokens + ignore_eos, temperature 0)
#   - unique real book text per run (--no-cache; no prefix-cache reuse)
#   - single stream (concurrency 1)
#
# The server must already be running (.\scripts\start.ps1). This runner never
# launches or restarts the server.
#
# Output:
#   results\qwen3.8-27b-rtx5090-sglang-dspark-3x2048.json  (llama-benchy receipt)
#   results\qwen3.8-27b-rtx5090-sglang-dspark-3x2048.md    (parsed tables)

[CmdletBinding()]
param(
    [int[]]$Contexts = @(4096, 8192, 16384, 32768, 65536, 131072),
    [int]$Runs = 3,
    [int]$OutputTokens = 2048,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')
# Import-Module (not dot-source): a .psm1 dot-sourced in PS 5.1 does not
# reliably expose its functions to the calling script.
Import-Module (Join-Path $PSScriptRoot 'Parse-LlamaBenchyResults.psm1') -Force

# --- Workload validation (defaults must pass their own validation) -----------
if (@($Contexts).Count -eq 0) { throw 'Contexts must not be empty.' }
if (@($Contexts | Sort-Object -Unique).Count -ne @($Contexts).Count) { throw 'Contexts must not contain duplicates.' }
$Contexts = @($Contexts | Sort-Object)
foreach ($c in $Contexts) { if ($c -lt 1) { throw "Context $c is not a positive token count." } }
if ($Runs -lt 1 -or $Runs -gt 10) { throw 'Runs must be between 1 and 10.' }
if ($OutputTokens -lt 16) { throw 'OutputTokens must be at least 16.' }

$prof = Get-RecipeProfile
$profile = $prof.Profile
$host_ = (Get-ProfileValue -Profile $profile -Name 'host' -Fallback '127.0.0.1')
$port = [int](Get-ProfileValue -Profile $profile -Name 'port' -Fallback 8080)
$container = (Get-ProfileValue -Profile $profile -Name 'containerName' -Fallback 'sglang-qwen38-lmhead4')
$modelId = (Get-ProfileValue -Profile $profile -Name 'modelId' -Fallback 'qwen3.8-27b')
$context = [int](Get-ProfileValue -Profile $profile -Name 'context' -Fallback 196608)
foreach ($c in $Contexts) {
    if ($c + $OutputTokens -gt $context) {
        throw "Rung $c + $OutputTokens output tokens exceeds the $context-token context. Lower the rung or the output length."
    }
}

$tokenizerDir = Join-Path (Get-RecipeLocalRoot) 'models\gittensor\Qwen3.8-27B-NVFP4-RTX5090-LMHead4'
if (-not (Test-Path -LiteralPath (Join-Path $tokenizerDir 'tokenizer.json') -PathType Leaf)) {
    throw "Tokenizer not found at $tokenizerDir. Run .\scripts\bootstrap.ps1 first."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot ("results\qwen3.8-27b-rtx5090-sglang-dspark-{0}x{1}.json" -f $Runs, $OutputTokens)
}

# --- Server preflight (never launch the server here) --------------------------
# SGLANG_BASE_URL (env) overrides the profile host:port -- used e.g. when the
# server is reachable only via a non-loopback route.
$baseUrlOverride = $env:SGLANG_BASE_URL
if ([string]::IsNullOrWhiteSpace($baseUrlOverride)) { $baseUrlOverride = "http://${host_}:${port}/v1" }
$endpoint = Get-SglangEndpoint -BaseUrl $baseUrlOverride
$apiKey = Get-SglangApiKey -ContainerName $container
try {
    $null = Invoke-SglangJson -Endpoint $endpoint -ApiKey $apiKey -Path '/health' -TimeoutSeconds 15
} catch {
    throw "The SGLang server is not healthy at http://${host_}:${port}/v1. Run .\scripts\start.ps1 first (this runner never starts the server)."
}
$models = Invoke-SglangJson -Endpoint $endpoint -ApiKey $apiKey -Path '/v1/models' -TimeoutSeconds 15
$ids = @($models.data | ForEach-Object { [string]$_.id })
if ($ids -notcontains $modelId) {
    throw "Model '$modelId' is not advertised ($($ids -join ', '))."
}
$info = Get-SglangServerInfo -Endpoint $endpoint -ApiKey $apiKey
$liveContext = [int]$info.context_length
if ($liveContext -lt $context) {
    Write-Warning "Server context_length is $liveContext, below the profile's $context. Rungs above $liveContext will fail."
}
Write-Host "Server: healthy at $($endpoint.BaseUrl) (model '$modelId', context $liveContext)"
Write-Host "Ladder: $([string]::Join(', ', @($Contexts | ForEach-Object { [string]$_ })))  x $Runs runs x $OutputTokens output tokens"
Write-Host ''

# --- llama-benchy availability -------------------------------------------------
$uvx = Get-Command uvx -ErrorAction SilentlyContinue
if ($null -eq $uvx) {
    throw 'uvx not found. Run .\benchmarks\install-llama-benchy.ps1 first.'
}

# --- Compose the llama-benchy invocation ---------------------------------------
# --extra-body return_token_ids=false: this SGLang image rejects that field in
# streaming requests (HTTP 400); llama-benchy sends it by default, and the
# override switches token counting to the response usage block.
# --extra-body temperature=0: deterministic sampling for the benchmark.
$uvArgs = @(
    '--from', 'llama-benchy==0.4.0', 'llama-benchy'
    '--base-url', $endpoint.BaseUrl
    '--api-key', $apiKey.Value
    '--model', $modelId
    '--tokenizer', $tokenizerDir
    '--pp'
)
$uvArgs += @($Contexts | ForEach-Object { [string]$_ })
$uvArgs += @(
    '--tg', [string]$OutputTokens
    '--depth', '0'
    '--runs', [string]$Runs
    '--exact-tg'
    '--no-cache'
    '--extra-body', 'temperature=0'
    '--extra-body', 'return_token_ids=false'
    '--save-result', $OutputPath
    '--format', 'json'
)

$gpuBefore = Get-GpuInfo

Write-Host "Running llama-benchy (6-rung ladder; 3 runs x 2,048 tokens, typically ~15-25 min)..."
$progressLog = Join-Path $env:TEMP "llama-benchy-progress-$([Guid]::NewGuid().ToString('N')).txt"
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $uvx.Source @uvArgs 2>&1 | Tee-Object -FilePath $progressLog
    $benchCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prevEap
}
if ($benchCode -ne 0) {
    throw "llama-benchy exited with code $benchCode. Progress: $progressLog"
}
$gpuAfter = Get-GpuInfo

# --- Parse + validate the receipt ----------------------------------------------
$doc = Read-LlamaBenchyJson -Path $OutputPath
$rungs = @(Get-LlamaBenchyRungs -Document $doc)

# Tolerance gate: llama-benchy reports each rung at its adapted prompt size
# (requested minus the chat-template overhead), so match within +/-512.
$found = 0
foreach ($expected in $Contexts) {
    $hit = $rungs | Where-Object { [Math]::Abs([int]$_.promptTokens - $expected) -le 512 }
    if ($null -eq $hit) {
        throw "No measured rung near $expected prompt tokens. Receipt: $OutputPath"
    }
    if ([int]$hit.runsMeasured -ne $Runs) {
        throw "Rung $([int]$hit.promptTokens) measured $($hit.runsMeasured) runs, expected $Runs."
    }
    $found++
}
if ($found -ne $Contexts.Count) { throw "Only $found of $($Contexts.Count) rungs were measured." }

# --- Render the summary receipt -------------------------------------------------
$mdPath = [IO.Path]::ChangeExtension($OutputPath, '.md')
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Qwen3.8-27B - RTX 5090 - SGLang -- llama-benchy ladder')
$lines.Add('')
$lines.Add([string]::Format('- llama-benchy {0} ({1}), latency {2} ms', $doc.version, $doc.timestamp, [math]::Round([double]$doc.latency_ms, 1)))
$lines.Add([string]::Format('- Model: `{0}` on SGLang (context {1}, KV dtype {2}, fp8 KV, FlashInfer, DSpark spec)', $modelId, $liveContext, [string]$info.kv_cache_dtype))
$lines.Add([string]::Format('- Workload: unique real book text, no prefix-cache reuse, {0} runs x {1} exact output tokens, temperature 0, single stream, per context: {2}', $Runs, $OutputTokens, ($Contexts -join ', ')))
if ($null -ne $gpuBefore) { $lines.Add([string]::Format('- GPU: {0} ({1} MiB total)', $gpuBefore.name, $gpuBefore.totalMiB)) }
$lines.Add('')
$md = Convert-RungsToMarkdown -Rungs $rungs -Title 'Results'
$lines.Add($md)
$lines.Add('')
$lines.Add('Raw per-run distribution: [' + [IO.Path]::GetFileName($OutputPath) + '](' + [IO.Path]::GetFileName($OutputPath) + ')')
[IO.File]::WriteAllText($mdPath, ($lines -join [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

# --- Console summary -------------------------------------------------------------
Write-Host ''
Write-Host ("Rung ladder (mean of {0} run(s)):" -f $Runs)
Write-Host ('{0,8} | {1,10} | {2,10} | {3,10}' -f 'context', 'prefill t/s', 'decode t/s', 'TTFT s')
foreach ($r in $rungs) {
    $ttftS = [math]::Round([double]$r.ttfrMsMean / 1000.0, 1)
    Write-Host ('{0,8} | {1,10} | {2,10} | {3,10}' -f ([string]::Format('{0:N0}', $r.promptTokens)), ('{0:N1}' -f $r.prefillTpsMean), ('{0:N1}' -f $r.decodeTpsMean), ('{0:N1}' -f $ttftS))
}
Write-Host ''
Write-Host "Receipt:  $OutputPath"
Write-Host "Summary:  $mdPath"
Remove-Item -LiteralPath $progressLog -Force -ErrorAction SilentlyContinue
exit 0
