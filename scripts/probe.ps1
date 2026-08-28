# probe.ps1 -- semantic capability probes against the running server.
#
#   .\scripts\probe.ps1
#
# Runs three gates (the same checks used when adopting the serving config):
#   1. Deep reasoning  -- a question that requires reasoning returns nonempty
#      reasoning_content with thinking on (the template default).
#   2. Thinking off    -- chat_template_kwargs {"enable_thinking": false}
#      returns a present reply with 0 reasoning characters.
#   3. Tool call       -- a function is offered and the model returns a
#      well-formed tool call with the expected name and parseable args.
#
# Exits 0 when all three pass.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$prof = Get-RecipeProfile
$profile = $prof.Profile
$host_ = (Get-ProfileValue -Profile $profile -Name 'host' -Fallback '127.0.0.1')
$port = [int](Get-ProfileValue -Profile $profile -Name 'port' -Fallback 8080)
$container = (Get-ProfileValue -Profile $profile -Name 'containerName' -Fallback 'sglang-qwen38-lmhead4')
$modelId = (Get-ProfileValue -Profile $profile -Name 'modelId' -Fallback 'qwen3.8-27b')

$apiKey = Get-SglangApiKey -ContainerName $container
$endpoint = Get-SglangEndpoint -BaseUrl "http://${host_}:${port}/v1"

function Invoke-Chat {
    param([object]$Messages, [object]$ChatTemplateKwargs, [object]$Tools, [int]$MaxTokens)
    $body = [ordered]@{
        model = $modelId
        messages = $Messages
        temperature = 0.0
        max_tokens = $MaxTokens
        stream = $false
    }
    if ($null -ne $ChatTemplateKwargs) { $body.chat_template_kwargs = $ChatTemplateKwargs }
    if ($null -ne $Tools) { $body.tools = $Tools }
    $json = $body | ConvertTo-Json -Depth 15 -Compress
    return Invoke-SglangJson -Endpoint $endpoint -ApiKey $apiKey -Path '/v1/chat/completions' -Method 'Post' -Body $json -TimeoutSeconds 300
}

$failures = 0

# --- Gate 1: deep reasoning (thinking on by default) ------------------------
Write-Host 'Gate 1: deep reasoning (thinking on)...'
try {
    $r = Invoke-Chat -Messages @(@{ role = 'user'; content = 'Think carefully, then answer in one sentence: what is the smallest prime factor of 91, and why?' }) `
        -ChatTemplateKwargs $null -Tools $null -MaxTokens 400
    $reasoning = [string]$r.choices[0].message.PSObject.Properties['reasoning_content'].Value
    $content = [string]$r.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($reasoning)) {
        throw 'reasoning_content was empty with thinking on (reasoning parser not producing reasoning).'
    }
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw 'content was empty on a reasoning question.'
    }
    Write-Host "  OK -- $($reasoning.Length) reasoning chars, answer: '$($content.Trim())'"
} catch {
    $failures++; Write-Warning "  FAIL -- $($_.Exception.Message)"
}

# --- Gate 2: thinking off -----------------------------------------------------
Write-Host 'Gate 2: thinking off (enable_thinking=false)...'
try {
    $r = Invoke-Chat -Messages @(@{ role = 'user'; content = 'What is 2+2? Answer in one word.' }) `
        -ChatTemplateKwargs @{ enable_thinking = $false } -Tools $null -MaxTokens 64
    $reasoning = [string]$r.choices[0].message.PSObject.Properties['reasoning_content'].Value
    $content = [string]$r.choices[0].message.content
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw 'content was empty with thinking off.'
    }
    if (-not [string]::IsNullOrWhiteSpace($reasoning)) {
        throw "thinking off still produced $($reasoning.Length) reasoning chars."
    }
    Write-Host "  OK -- reply: '$($content.Trim())', 0 reasoning chars"
} catch {
    $failures++; Write-Warning "  FAIL -- $($_.Exception.Message)"
}

# --- Gate 3: tool call round-trip --------------------------------------------
Write-Host 'Gate 3: tool call round-trip...'
try {
    $tools = @(@{
        type = 'function'
        function = @{
            name = 'get_weather'
            description = 'Get the current weather for a city.'
            parameters = @{
                type = 'object'
                properties = @{
                    city = @{ type = 'string'; description = 'City name' }
                }
                required = @('city')
            }
        }
    })
    $r = Invoke-Chat -Messages @(@{ role = 'user'; content = 'What is the weather in London right now?' }) `
        -ChatTemplateKwargs $null -Tools $tools -MaxTokens 256
    $choice = $r.choices[0]
    # tool_calls live on choice.message (OpenAI schema); fall back to the
    # choice itself and to a top-level function_call for older shapes.
    $tc = $choice.message.PSObject.Properties['tool_calls']
    if ($null -eq $tc -or @($tc.Value).Count -eq 0) {
        $tc = $choice.PSObject.Properties['tool_calls']
    }
    if ($null -eq $tc -or @($tc.Value).Count -eq 0) {
        $fn = $choice.PSObject.Properties['function_call']
        throw "no tool_calls (finish_reason=$($choice.finish_reason))."
    }
    $call = @($tc.Value)[0]
    $name = [string]$call.function.name
    if ($name -ne 'get_weather') { throw "wrong function name '$name'." }
    $argsJson = [string]$call.function.arguments
    $parsed = $argsJson | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$parsed.city)) { throw "arguments did not parse to a city: $argsJson" }
    Write-Host "  OK -- $name(city='$($parsed.city)')"
} catch {
    $failures++; Write-Warning "  FAIL -- $($_.Exception.Message)"
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "Probe complete: $failures gate(s) failed."
    exit 1
}
Write-Host 'Probe complete: all 3 gates passed.'
exit 0
