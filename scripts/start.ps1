# start.ps1 -- launch the SGLang server container.
#
#   .\scripts\start.ps1
#
# Creates the API key once (if missing), stops any stale container with the
# same name, launches the digest-pinned image with the recipe's serving flags,
# then gates on: health 200, model identity, and a deterministic chat
# round-trip. Exits 0 only when all gates pass.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$LocalRoot = Get-RecipeLocalRoot
$prof = Get-RecipeProfile
$profile = $prof.Profile

$host_ = (Get-ProfileValue -Profile $profile -Name 'host' -Fallback '127.0.0.1')
$port = [int](Get-ProfileValue -Profile $profile -Name 'port' -Fallback 8080)
$container = (Get-ProfileValue -Profile $profile -Name 'containerName' -Fallback 'sglang-qwen38')
$image = (Get-ProfileValue -Profile $profile -Name 'image')
$context = [int](Get-ProfileValue -Profile $profile -Name 'context' -Fallback 163840)
$modelId = (Get-ProfileValue -Profile $profile -Name 'modelId' -Fallback 'qwen3.8-27b')
$memFraction = (Get-ProfileValue -Profile $profile -Name 'memFractionStatic' -Fallback 0.95)
$kvDtype = (Get-ProfileValue -Profile $profile -Name 'kvCacheDtype' -Fallback 'fp8_e4m3')
$attn = (Get-ProfileValue -Profile $profile -Name 'attentionBackend' -Fallback 'flashinfer')
$chunked = [int](Get-ProfileValue -Profile $profile -Name 'chunkedPrefillSize' -Fallback 2048)
$maxRunning = [int](Get-ProfileValue -Profile $profile -Name 'maxRunningRequests' -Fallback 1)
$mambaDtype = (Get-ProfileValue -Profile $profile -Name 'mambaSsmDtype' -Fallback 'bfloat16')
$spec = $profile.PSObject.Properties['speculative'].Value
if ([string]::IsNullOrWhiteSpace($image)) { throw 'Profile is missing "image".' }
if ($image -notmatch '@sha256:') { throw 'Profile image must be digest-pinned (repo@sha256:...). Refusing to start by tag.' }

# Mount the PARENT model dirs (models\gittensor, models\RadixArk) and address
# the model subdirectories in-container:
#   -v C:\local-llm\models\gittensor:/models/base:ro  -> /models/base/Qwen3.8-27B-NVFP4-RTX5090
#   -v C:\local-llm\models\RadixArk:/models/draft:ro  -> /models/draft/Qwen3.8-27B-DSpark
$baseMount = Join-Path $LocalRoot 'models\gittensor'
$draftMount = Join-Path $LocalRoot 'models\RadixArk'
$modelDir = Join-Path $baseMount 'Qwen3.8-27B-NVFP4-RTX5090'
$draftDir = Join-Path $draftMount 'Qwen3.8-27B-DSpark'
if (-not (Test-Path -LiteralPath $modelDir -PathType Container)) { throw "Model not found at $modelDir. Run .\scripts\bootstrap.ps1 first." }
if (-not (Test-Path -LiteralPath $draftDir -PathType Container)) { throw "Draft not found at $draftDir. Run .\scripts\bootstrap.ps1 first." }

# --- API key (create once, protect, reuse forever) --------------------------
$key = New-RecipeApiKey
Write-Host "API key: $($key.Path) (reused; never printed)"

# --- Stop stale container ----------------------------------------------------
$stale = Get-DockerContainerState -Name $container
if ($null -ne $stale) {
    Write-Host "Stopping stale container '$container' (status: $($stale.Status))..."
    $rm = Invoke-NativeSafe -FilePath 'docker' -ArgumentList @('rm', '-f', $container) -AllowFail
    if ($rm.Code -ne 0) { throw "Could not remove stale container '$container'." }
}

# --- Launch ------------------------------------------------------------------
# Windows host paths must be C:\... for Docker Desktop. Convert LOCAL_LLM_ROOT.
# (The recipe root is already a Windows path on a Windows host; on WSL the
# recipe is not run -- Docker Desktop needs the C:\ mount.)
$run = @(
    'run', '-d', '--name', $container
    '--gpus', 'all'
    '--shm-size', '32g'
    '-p', "127.0.0.1:${port}:${port}"
    '-v', "${baseMount}:/models/base:ro"
    '-v', "${draftMount}:/models/draft:ro"
    $image
    'python3', '-m', 'sglang.launch_server'
    '--model-path', '/models/base/Qwen3.8-27B-NVFP4-RTX5090'
    '--served-model-name', $modelId
    '--host', '0.0.0.0'
    '--port', [string]$port
    '--api-key', $key.Value
    '--speculative-algorithm', (Get-ProfileValue -Profile $spec -Name 'algorithm' -Fallback 'DSPARK')
    '--speculative-draft-model-path', '/models/draft/Qwen3.8-27B-DSpark'
    '--speculative-draft-model-quantization', (Get-ProfileValue -Profile $spec -Name 'draftQuantization' -Fallback 'fp8')
    '--speculative-num-steps', [string](Get-ProfileValue -Profile $spec -Name 'numSteps' -Fallback 7)
    '--speculative-eagle-topk', [string](Get-ProfileValue -Profile $spec -Name 'eagleTopk' -Fallback 1)
    '--speculative-num-draft-tokens', [string](Get-ProfileValue -Profile $spec -Name 'numDraftTokens' -Fallback 8)
    '--attention-backend', $attn
    '--kv-cache-dtype', $kvDtype
    '--context-length', [string]$context
    '--language-only'
    '--mem-fraction-static', [string]$memFraction
    '--max-running-requests', [string]$maxRunning
    '--disable-radix-cache'
    '--mamba-ssm-dtype', $mambaDtype
    '--chunked-prefill-size', [string]$chunked
    '--reasoning-parser', 'qwen3'
    '--tool-call-parser', 'qwen3_coder'
)
Write-Host "Starting container '$container'..."
$launch = Invoke-NativeSafe -FilePath 'docker' -ArgumentList $run -AllowFail
if ($launch.Code -ne 0) {
    $tail = @($launch.Lines | Where-Object { $_ } | Select-Object -Last 8)
    throw "docker run failed (exit $($launch.Code)).`n$($tail -join [Environment]::NewLine)"
}
Write-Host 'Container launched. Waiting for readiness (SGLang load is ~2-4 min)...'

# --- Readiness gate ----------------------------------------------------------
$endpoint = Get-SglangEndpoint -BaseUrl "http://${host_}:${port}/v1"
$apiKeyObj = [pscustomobject]@{ Value = $key.Value; Source = 'startup' }
$ready = $false
$deadline = (Get-Date).AddMinutes(10)
$lastErr = ''
while ((Get-Date) -lt $deadline) {
    try {
        $h = Invoke-SglangJson -Endpoint $endpoint -ApiKey $apiKeyObj -Path '/health' -TimeoutSeconds 10
        $hVal = $h
        $models = Invoke-SglangJson -Endpoint $endpoint -ApiKey $apiKeyObj -Path '/v1/models' -TimeoutSeconds 15
        $ids = @($models.data | ForEach-Object { [string]$_.id })
        if ($ids -contains $modelId) { $ready = $true; break }
        $lastErr = "healthy but model '$modelId' not advertised yet ($($ids -join ', '))"
    } catch {
        $lastErr = $_.Exception.Message
    }
    Start-Sleep -Seconds 10
}
if (-not $ready) {
    $logs = Invoke-NativeSafe -FilePath 'docker' -ArgumentList @('logs', '--tail', '40', $container) -AllowFail
    $tail = @($logs.Lines | Where-Object { $_ } | Select-Object -Last 40)
    throw "Readiness gate failed after 10 min. Last error: $lastErr`nContainer log tail:`n$($tail -join [Environment]::NewLine)"
}
Write-Host "Readiness: OK (health + model identity '$modelId')"

# --- Context + KV gate -------------------------------------------------------
$info = Get-SglangServerInfo -Endpoint $endpoint -ApiKey $apiKeyObj
$ctx = [int]$info.context_length
if ($ctx -lt $context) {
    Write-Warning "Server context_length is $ctx, below the requested $context. Check VRAM / mem-fraction."
}
$states = @($info.PSObject.Properties['internal_states'].Value)
$kvCap = $null
if ($states.Count -gt 0) {
    $mu = $states[0].PSObject.Properties['memory_usage']
    if ($null -ne $mu) { $kvCap = [int]$mu.Value.PSObject.Properties['token_capacity'].Value }
}
if ($null -ne $kvCap) {
    Write-Host "KV token capacity: $kvCap (configured context $ctx)"
}

# --- Chat round-trip gate (deterministic, thinking off) ----------------------
$body = @{
    model = $modelId
    messages = @(@{ role = 'user'; content = 'Reply with exactly the word: ok' })
    temperature = 0.0
    max_tokens = 16
    stream = $false
    chat_template_kwargs = @{ enable_thinking = $false }
} | ConvertTo-Json -Depth 10
$resp = Invoke-SglangJson -Endpoint $endpoint -ApiKey $apiKeyObj -Path '/v1/chat/completions' -Method 'Post' -Body $body -TimeoutSeconds 120
$content = [string]$resp.choices[0].message.content
if ([string]::IsNullOrWhiteSpace($content)) {
    throw "Chat round-trip returned empty content (finish_reason=$($resp.choices[0].finish_reason))."
}
Write-Host "Chat round-trip: OK ('$($content.Trim())')"

Write-Host ''
Write-Host "SGLang server is live on http://${host_}:${port}/v1 (model '$modelId')."
Write-Host "Benchmark: .\benchmarks\bench.ps1"
exit 0
