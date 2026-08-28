# Shared helpers for the SGLang recipe.
#
# PowerShell 5.1 compatible. Native commands (docker, hf, nvidia-smi) are
# always invoked through Invoke-NativeSafe: PowerShell 5.1 with
# $ErrorActionPreference='Stop' treats ANY native stderr as a terminating
# NativeCommandError, which aborts multi-line scripts on benign hint output.

$script:RecipeRoot = Split-Path -Parent $PSScriptRoot
$script:RecipeName = 'Qwen3.8-27B-RTX-5090-SGLang'

function Invoke-NativeSafe {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$AllowFail
    )

    $prevEap = $ErrorActionPreference
    $prevOutEnc = $null
    try {
        $ErrorActionPreference = 'Continue'
        try { $prevOutEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
        $prevPyEnc = $env:PYTHONIOENCODING
        $env:PYTHONIOENCODING = 'utf-8'
        $lines = @(& $FilePath @ArgumentList 2>&1)
        $code = $LASTEXITCODE
        return [pscustomobject]@{ Code = $code; Lines = @($lines) }
    }
    finally {
        $ErrorActionPreference = $prevEap
        if ($null -ne $prevOutEnc) { try { [Console]::OutputEncoding = $prevOutEnc } catch {} }
        if ($null -eq $prevPyEnc) { Remove-Item Env:\PYTHONIOENCODING -ErrorAction SilentlyContinue } else { $env:PYTHONIOENCODING = $prevPyEnc }
    }
}

function Test-CommandAvailable {
    param([Parameter(Mandatory)][string]$Name)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $found = $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
    $ErrorActionPreference = $prevEap
    return $found
}

function Get-RecipeLocalRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:LOCAL_LLM_ROOT)) { return $env:LOCAL_LLM_ROOT.TrimEnd('\') }
    return 'C:\local-llm'
}

function Get-RecipeProfile {
    param([switch]$RequireLocal)
    $local = Join-Path $script:RecipeRoot 'config\profile.json'
    $example = Join-Path $script:RecipeRoot 'config\profile.example.json'
    if ((Test-Path -LiteralPath $local -PathType Leaf) -and -not $RequireLocal) {
        $path = $local
    }
    elseif (Test-Path -LiteralPath $local -PathType Leaf) {
        $path = $local
    }
    else {
        if ($RequireLocal) { throw "No local config\profile.json found (copy config\profile.example.json and adjust)." }
        $path = $example
    }
    $raw = [IO.File]::ReadAllText($path)
    # Code-point BOM check (PS 5.1 stringifies [char]0xFEFF to "" and makes
    # StartsWith always true -- see Parse-LlamaBenchyResults.psm1).
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    return @{ Path = $path; Profile = ($raw | ConvertFrom-Json) }
}

function Get-ProfileValue {
    param([Parameter(Mandatory)][object]$Profile, [string]$Name, $Fallback)
    $value = $Profile.PSObject.Properties[$Name]
    if ($null -ne $value -and $null -ne $value.Value) { return $value.Value }
    return $Fallback
}

function Get-ModelDir {
    return Join-Path $env:LOCALAPPDATA $script:RecipeName
}

function Protect-RecipeApiKeyFile {
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($identity in @($env:USERNAME, 'SYSTEM', 'Administrators')) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
        $acl.SetAccessRule($rule)
    }
    $acl | Set-Acl -LiteralPath $Path
}

function New-RecipeApiKey {
    # Creates the one-line API key once, under %LOCALAPPDATA%\<Recipe>, with a
    # protected ACL. Never regenerated on subsequent launches.
    $dir = Get-ModelDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $path = Join-Path $dir 'sglang.key'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $bytes = New-Object byte[] 32
        (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($bytes)
        $value = [Convert]::ToBase64String($bytes).Replace('+', '').Replace('/', '').Substring(0, 32)
        [IO.File]::WriteAllText($path, $value, [Text.UTF8Encoding]::new($false))
        Protect-RecipeApiKeyFile -Path $path
    }
    return [pscustomobject]@{ Path = $path; Value = ([IO.File]::ReadAllText($path).Trim()) }
}

function Get-SglangEndpoint {
    param([string]$BaseUrl, [int]$ProfilePort = 8080)
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        if (-not [string]::IsNullOrWhiteSpace($env:SGLANG_BASE_URL)) {
            $BaseUrl = $env:SGLANG_BASE_URL
        } else {
            $BaseUrl = "http://127.0.0.1:$ProfilePort/v1"
        }
    }
    $BaseUrl = $BaseUrl.TrimEnd('/')
    $uri = [Uri]$BaseUrl
    if ($uri.Scheme -ne 'http' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'SGLANG_BASE_URL must be an http URL without credentials, query, or fragment.'
    }
    # Loopback always allowed. Tailscale CGNAT (100.64.0.0/10, here approximated
    # as 100.0.0.0/1) and *.ts.net hosts are allowed too, for servers reached
    # over a private overlay network.
    $isLoopback = @('localhost', '127.0.0.1', '::1') -contains $uri.Host
    $isTailscale = $uri.HostName -like '*.ts.net'
    if (-not $isTailscale) {
        try {
            $ip = [System.Net.IPAddress]::Parse($uri.Host)
            $isTailscale = ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) -and
                           ($ip.GetAddressBytes()[0] -ge 100 -and $ip.GetAddressBytes()[0] -le 127)
        } catch { }
    }
    if (-not $isLoopback -and -not $isTailscale) {
        throw "SGLANG_BASE_URL must target loopback or a Tailscale (100.64.0.0/10, *.ts.net) host; received '$($uri.Host)'."
    }
    if (-not $uri.AbsolutePath.TrimEnd('/').EndsWith('/v1', [StringComparison]::OrdinalIgnoreCase)) {
        $BaseUrl = "$BaseUrl/v1"
    }
    return [pscustomobject]@{
        BaseUrl   = $BaseUrl
        RootUrl   = ([Uri]$BaseUrl).GetLeftPart([UriPartial]::Authority)
        ApiUrl    = $BaseUrl
    }
}

function Get-SglangApiKey {
    param([string]$ContainerName)
    foreach ($name in @('SGLANG_API_KEY', 'QWEN_SGLANG_API_KEY')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [pscustomobject]@{ Value = $value.Trim(); Source = "environment:$name" }
        }
    }
    $keyPath = [Environment]::GetEnvironmentVariable('SGLANG_API_KEY_FILE')
    if ([string]::IsNullOrWhiteSpace($keyPath)) { $keyPath = Join-Path (Get-ModelDir) 'sglang.key' }
    if (Test-Path -LiteralPath $keyPath -PathType Leaf) {
        $value = ([IO.File]::ReadAllText($keyPath)).Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return [pscustomobject]@{ Value = $value; Source = "file:$keyPath" }
        }
    }
    if ([string]::IsNullOrWhiteSpace($ContainerName)) { $ContainerName = 'sglang-qwen38-lmhead4' }
    if (Test-CommandAvailable -Name 'docker') {
        $res = Invoke-NativeSafe -FilePath 'docker' -ArgumentList @('inspect', '--format', '{{json .Config.Cmd}}', $ContainerName) -AllowFail
        if ($res.Code -eq 0) {
            $raw = ($res.Lines | Where-Object { $_ }) -join "`n"
            if ($raw -match '^"') {
                try {
                    $argsJson = $raw | ConvertFrom-Json
                    if ($argsJson -is [Array]) { $cmd = @($argsJson) } else { $cmd = @($argsJson) }
                    for ($i = 0; $i -lt ($cmd.Count - 1); $i++) {
                        if ([string]$cmd[$i] -eq '--api-key' -and -not [string]::IsNullOrWhiteSpace([string]$cmd[$i + 1])) {
                            return [pscustomobject]@{ Value = [string]$cmd[$i + 1]; Source = "docker:$ContainerName" }
                        }
                    }
                } catch { }
            }
        }
    }
    throw "No SGLang API key found. Run scripts\start.ps1 (auto-creates $keyPath), or set SGLANG_API_KEY / SGLANG_API_KEY_FILE."
}

function Get-SglangHeaders {
    param([Parameter(Mandatory)][object]$ApiKey)
    return @{ Authorization = "Bearer $($ApiKey.Value)"; 'Content-Type' = 'application/json' }
}

function Invoke-SglangJson {
    param(
        [Parameter(Mandatory)][object]$Endpoint,
        [Parameter(Mandatory)][object]$ApiKey,
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Get', 'Post')][string]$Method = 'Get',
        [string]$Body,
        [int]$TimeoutSeconds = 30
    )

    $uri = "$($Endpoint.RootUrl)$Path"
    # Use Invoke-WebRequest (not RestMethod): /health returns 200 with an
    # EMPTY body, which makes RestMethod throw. Tolerate that here.
    $web = @{
        Uri = $uri
        Method = $Method
        Headers = Get-SglangHeaders -ApiKey $ApiKey
        TimeoutSec = $TimeoutSeconds
        UseBasicParsing = $true
        ErrorAction = 'Stop'
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $web.Body = $Body }
    $resp = Invoke-WebRequest @web
    if ([string]::IsNullOrWhiteSpace([string]$resp.Content)) { return $null }
    return ($resp.Content | ConvertFrom-Json)
}

function Get-SglangServerInfo {
    param(
        [Parameter(Mandatory)][object]$Endpoint,
        [Parameter(Mandatory)][object]$ApiKey
    )
    try {
        return Invoke-SglangJson -Endpoint $Endpoint -ApiKey $ApiKey -Path '/get_server_info' -TimeoutSeconds 30
    } catch {
        return Invoke-SglangJson -Endpoint $Endpoint -ApiKey $ApiKey -Path '/server_info' -TimeoutSeconds 30
    }
}

function Get-GpuInfo {
    if (-not (Test-CommandAvailable -Name 'nvidia-smi')) { return $null }
    $res = Invoke-NativeSafe -FilePath 'nvidia-smi' -ArgumentList @(
        '--query-gpu=name,memory.used,memory.total,memory.free,utilization.gpu,temperature.gpu'
        '--format=csv,noheader,nounits') -AllowFail
    if ($res.Code -ne 0) { return $null }
    $line = @($res.Lines | Where-Object { $_ } | Select-Object -First 1)
    if ($line.Count -eq 0) { return $null }
    $parts = @($line[0] -split ',')
    if ($parts.Count -lt 6) { return $null }
    return [ordered]@{
        name = $parts[0].Trim()
        usedMiB = [int]$parts[1].Trim()
        totalMiB = [int]$parts[2].Trim()
        freeMiB = [int]$parts[3].Trim()
        utilizationPercent = [int]$parts[4].Trim()
        temperatureC = [int]$parts[5].Trim()
    }
}

function Write-JsonNoBom {
    param(
        [Parameter(Mandatory)][object]$Value,
        [Parameter(Mandatory)][string]$Path,
        [int]$Depth = 30
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth $Depth
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
    return $Path
}

function Get-DockerContainerState {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-CommandAvailable -Name 'docker')) { return $null }
    $res = Invoke-NativeSafe -FilePath 'docker' -ArgumentList @(
        'inspect', '--format', '{{.State.Status}}|{{.NetworkSettings.Ports}}', $Name) -AllowFail
    if ($res.Code -ne 0) { return $null }
    $raw = @($res.Lines | Where-Object { $_ } | Select-Object -First 1)
    if ($raw.Count -eq 0) { return $null }
    $parts = @($raw[0] -split '\|')
    return [pscustomobject]@{ Status = $parts[0].Trim(); Ports = $parts[1] }
}
