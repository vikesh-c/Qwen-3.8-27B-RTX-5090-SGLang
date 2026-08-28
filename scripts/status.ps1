# status.ps1 -- report the SGLang server's state.
#
#   .\scripts\status.ps1
#
# Prints container status, GPU usage, and (when the server is up) health,
# advertised model, configured context, and KV token capacity.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$prof = Get-RecipeProfile
$profile = $prof.Profile
$host_ = (Get-ProfileValue -Profile $profile -Name 'host' -Fallback '127.0.0.1')
$port = [int](Get-ProfileValue -Profile $profile -Name 'port' -Fallback 8080)
$container = (Get-ProfileValue -Profile $profile -Name 'containerName' -Fallback 'sglang-qwen38-lmhead4')
$modelId = (Get-ProfileValue -Profile $profile -Name 'modelId' -Fallback 'qwen3.8-27b')

Write-Host "Recipe:   $script:RecipeName"
Write-Host "Profile:  $($prof.Path)"

$state = Get-DockerContainerState -Name $container
if ($null -eq $state) {
    Write-Host "Container: $container -- not running"
} else {
    Write-Host "Container: $container -- $($state.Status)"
}

$gpu = Get-GpuInfo
if ($null -ne $gpu) {
    Write-Host "GPU:      $($gpu.name) -- $($gpu.usedMiB)/$($gpu.totalMiB) MiB used, $($gpu.utilizationPercent)% util, $($gpu.temperatureC)C"
} else {
    Write-Host 'GPU:      nvidia-smi unavailable'
}

$apiKey = $null
try { $apiKey = Get-SglangApiKey -ContainerName $container } catch { }
if ($null -eq $apiKey) {
    Write-Host 'Server:   no API key found (server likely down or key unset)'
    exit 0
}

$endpoint = Get-SglangEndpoint -BaseUrl "http://${host_}:${port}/v1"
try {
    $null = Invoke-SglangJson -Endpoint $endpoint -ApiKey $apiKey -Path '/health' -TimeoutSeconds 10
    Write-Host "Server:   healthy at http://${host_}:${port}/v1"
} catch {
    Write-Host 'Server:   container present but HTTP health check failed'
    exit 0
}

try {
    $models = Invoke-SglangJson -Endpoint $endpoint -ApiKey $apiKey -Path '/v1/models' -TimeoutSeconds 10
    $ids = @($models.data | ForEach-Object { [string]$_.id })
    Write-Host "Models:   $($ids -join ', ')"
    if ($ids -notcontains $modelId) { Write-Warning "Expected model '$modelId' is not advertised." }

    $info = Get-SglangServerInfo -Endpoint $endpoint -ApiKey $apiKey
    $ctx = [int]$info.context_length
    $kvDtype = [string]$info.kv_cache_dtype
    $states = @($info.PSObject.Properties['internal_states'].Value)
    $kvCap = $null; $weightsGb = $null
    if ($states.Count -gt 0) {
        $mu = $states[0].PSObject.Properties['memory_usage']
        if ($null -ne $mu) {
            $kvCap = [int]$mu.Value.PSObject.Properties['token_capacity'].Value
            $weightsGb = [math]::Round([double]$mu.Value.PSObject.Properties['weight'].Value, 1)
        }
    }
    Write-Host "Context:  $ctx (KV dtype $kvDtype, token capacity $kvCap, weights ~$weightsGb GB)"
} catch {
    Write-Warning "Server details unavailable: $($_.Exception.Message)"
}
exit 0
