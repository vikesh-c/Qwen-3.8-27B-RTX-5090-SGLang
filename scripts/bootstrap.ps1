# bootstrap.ps1 -- zero-to-launch install for the SGLang recipe.
#
#   .\scripts\bootstrap.ps1
#
# Idempotent, Windows-side Docker Desktop path (no WSL or Linux-toolkit
# dependency):
#   1. Ensures Docker Desktop is installed (installs via winget if missing).
#   2. Ensures the Docker engine is running (starts Docker Desktop if needed).
#   3. Verifies NVIDIA GPU support.
#   4. Gates on Hugging Face auth (installs the hf CLI if missing, walks login).
#   5. Downloads the model + draft weights at their pinned revisions.
#   6. Pulls the digest-pinned SGLang Docker image.
#   7. Launches the server container and waits for readiness (start.ps1).
#
# Safe to re-run at any point: every step checks current state first, so a
# re-run picks up where the machine already is (engine up, files present,
# image present, container already serving) without repeating work.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'common.ps1')

$LocalRoot = Get-RecipeLocalRoot
Write-Host "Recipe root: $LocalRoot"

# --- 1. Docker Desktop present? --------------------------------------------
$DockerDesktopExe = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'

function Get-DockerCli {
    $cmd = Get-Command docker -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    $known = 'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
    if (Test-Path -LiteralPath $known -PathType Leaf) { return $known }
    return $null
}

$dockerCli = Get-DockerCli
if ($null -eq $dockerCli) {
    if (-not (Test-CommandAvailable -Name 'winget')) {
        throw 'Neither Docker Desktop nor winget was found. Install Docker Desktop for Windows from https://www.docker.com/products/docker-desktop/ (or install winget first), then re-run bootstrap.'
    }
    Write-Host 'Docker Desktop is not installed. Installing via winget (may prompt for elevation / acceptance)...'
    $inst = Invoke-NativeSafe -FilePath 'winget' -ArgumentList @(
        'install', '--id', 'Docker.DockerDesktop', '-e',
        '--accept-source-agreements', '--accept-package-agreements') -AllowFail
    if ($inst.Code -ne 0) {
        $tail = @($inst.Lines | Where-Object { $_ } | Select-Object -Last 8)
        throw "winget install of Docker Desktop failed (exit $($inst.Code)).`n$($tail -join [Environment]::NewLine)"
    }
    $dockerCli = Get-DockerCli
    if ($null -eq $dockerCli) {
        throw 'Docker Desktop installed, but docker.exe is not yet on PATH. Open a new PowerShell window and re-run bootstrap.'
    }
    Write-Host 'Docker Desktop installed.'
} else {
    Write-Host "Docker Desktop CLI: $dockerCli"
}

# --- 2. Docker engine running? ----------------------------------------------
function Test-DockerEngine {
    param([string]$Cli)
    $res = Invoke-NativeSafe -FilePath $Cli -ArgumentList @('info', '--format', '{{.ServerVersion}}') -AllowFail
    return $res
}

$engine = Test-DockerEngine -Cli $dockerCli
if ($engine.Code -ne 0) {
    Write-Host 'Docker engine is not reachable. Starting Docker Desktop...'
    if (Test-Path -LiteralPath $DockerDesktopExe -PathType Leaf) {
        Start-Process -FilePath $DockerDesktopExe | Out-Null
    } else {
        Start-Process -FilePath $dockerCli -ArgumentList @('desktop', 'start') | Out-Null
    }
    $ready = $false
    $deadline = (Get-Date).AddMinutes(6)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $engine = Test-DockerEngine -Cli $dockerCli
        if ($engine.Code -eq 0) { $ready = $true; break }
    }
    if (-not $ready) {
        throw 'Docker engine did not become reachable within 6 minutes. Open Docker Desktop once to accept its license, then re-run bootstrap.'
    }
}
Write-Host "Docker engine: $((@($engine.Lines | Where-Object { $_ }) | Select-Object -First 1))"

# --- 3. GPU support ----------------------------------------------------------
$gpu = Get-GpuInfo
if ($null -eq $gpu) {
    throw 'nvidia-smi reported no GPU. Check the NVIDIA driver; Docker Desktop for Windows exposes the GPU through its own backend once the driver is installed.'
}
Write-Host "GPU: $($gpu.name)  ($($gpu.totalMiB) MiB total, $($gpu.usedMiB) MiB used)"
if ($gpu.totalMiB -lt 30000) {
    Write-Warning 'This GPU has less than 30 GiB VRAM. The recipe is tuned for a 32 GiB RTX 5090; expect context or KV-pool shrinkage.'
}

# --- 4. Hugging Face auth gate ---------------------------------------------
function Test-HfAuthenticated {
    $res = Invoke-NativeSafe -FilePath 'hf' -ArgumentList @('auth', 'whoami') -AllowFail
    return $res.Code -eq 0
}

$hfOk = Test-CommandAvailable -Name 'hf'
if (-not $hfOk) {
    Write-Host 'hf CLI not found -- installing huggingface_hub[cli] via pip...'
    if (-not (Test-CommandAvailable -Name 'python')) { throw 'No python on PATH. Install Python 3.10+ (with pip) or the hf CLI before re-running bootstrap.' }
    $pip = Invoke-NativeSafe -FilePath 'python' -ArgumentList @('-m', 'pip', 'install', '-U', 'huggingface_hub[cli]') -AllowFail
    if ($pip.Code -ne 0) { throw 'pip install huggingface_hub[cli] failed. See the output above.' }
}

if (-not (Test-HfAuthenticated)) {
    Write-Host ''
    Write-Host 'Hugging Face authentication is required for the model download.'
    Write-Host 'Run:  hf auth login'
    Write-Host 'and paste the access token from https://huggingface.co/settings/tokens'
    Write-Host '(a free read-only token is enough; both repositories are public). Press Enter when done...'
    [void][Console]::ReadLine()
    if (-not (Test-HfAuthenticated)) {
        throw 'Hugging Face auth is still not active. Complete "hf auth login" and re-run bootstrap.'
    }
}
Write-Host 'Hugging Face auth: OK'

# --- 5. Model + draft weights (revision-pinned) -----------------------------
$profile = (Get-RecipeProfile).Profile
$modelRepo = (Get-ProfileValue -Profile $profile -Name 'modelRepo')
if ([string]::IsNullOrWhiteSpace($modelRepo)) {
    $artifacts = $profile.PSObject.Properties['artifacts']
    $modelRepo = if ($null -ne $artifacts) { $artifacts.Value.PSObject.Properties['modelRepo'].Value } else { $null }
}
$modelRevision = (Get-ProfileValue -Profile $profile -Name 'modelRevision')
$draftRepo = (Get-ProfileValue -Profile $profile -Name 'draftRepo')
$draftRevision = (Get-ProfileValue -Profile $profile -Name 'draftRevision')
if ($null -eq $modelRevision -or $null -eq $draftRevision) {
    $art = $profile.PSObject.Properties['artifacts'].Value
    if ($null -eq $modelRevision) { $modelRevision = $art.PSObject.Properties['modelRevision'].Value }
    if ($null -eq $draftRevision) { $draftRevision = $art.PSObject.Properties['draftRevision'].Value }
    if ($null -eq $modelRepo) { $modelRepo = $art.PSObject.Properties['modelRepo'].Value }
    if ($null -eq $draftRepo) { $draftRepo = $art.PSObject.Properties['draftRepo'].Value }
}
$modelDir = Join-Path $LocalRoot 'models\gittensor\Qwen3.8-27B-NVFP4-RTX5090-LMHead4'
# The draft is downloaded to its upstream-named directory, then copied to the
# bf16cast serving directory with one config.json change (dtype float16 ->
# bfloat16; weights stay byte-identical). SGLang's DSpark projector feeds BF16
# target hidden states into the draft's fc projection; with the upstream
# float16 config that projection crashes with
# "RuntimeError: expected mat1 and mat2 to have the same dtype, but got:
#  c10::BFloat16 != c10::Half" on the first speculative decode. Loading the
# residuals as bfloat16 matches them to the target stream and serves cleanly.
$draftUpstreamDir = Join-Path $LocalRoot 'models\gittensor\Qwen3.8-27B-DSpark-NVFP4-eba1ac5a'
$draftDir = Join-Path $LocalRoot 'models\gittensor\Qwen3.8-27B-DSpark-NVFP4-eba1ac5a-fp16residual-bf16cast'

function Invoke-HfDownload {
    param([string]$Repo, [string]$Revision, [string]$LocalDir)
    Write-Host "Downloading $Repo @ $Revision -> $LocalDir"
    $res = Invoke-NativeSafe -FilePath 'hf' -ArgumentList @(
        'download', $Repo,
        '--revision', $Revision,
        '--local-dir', $LocalDir
    ) -AllowFail
    if ($res.Code -ne 0) {
        throw "hf download failed for $Repo (exit $($res.Code))."
    }
}

Invoke-HfDownload -Repo $modelRepo -Revision $modelRevision -LocalDir $modelDir
Invoke-HfDownload -Repo $draftRepo -Revision $draftRevision -LocalDir $draftUpstreamDir

# Build (or refresh) the bf16cast draft directory from the upstream download.
$draftConfig = Join-Path $draftUpstreamDir 'config.json'
if (-not (Test-Path -LiteralPath $draftConfig -PathType Leaf)) {
    throw "Draft download verified, but $draftConfig is missing."
}
$raw = [IO.File]::ReadAllText($draftConfig)
if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
$cfg = $raw | ConvertFrom-Json
$cfg.dtype = 'bfloat16'
New-Item -ItemType Directory -Path $draftDir -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $draftUpstreamDir '*') -Destination $draftDir -Recurse -Force
[IO.File]::WriteAllText((Join-Path $draftDir 'config.json'), ($cfg | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))

$tokenizerCheck = Join-Path $modelDir 'tokenizer.json'
if (-not (Test-Path -LiteralPath $tokenizerCheck -PathType Leaf)) {
    throw "Model download verified, but $tokenizerCheck is missing. The benchmark runner needs the tokenizer."
}
$draftWeightsCheck = Join-Path $draftDir 'model.safetensors'
if (-not (Test-Path -LiteralPath $draftWeightsCheck -PathType Leaf)) {
    throw "Draft bf16cast directory is missing model.safetensors at $draftWeightsCheck."
}
Write-Host "Model + tokenizer: $modelDir"
Write-Host "Draft (bf16cast):  $draftDir"

# --- 6. Docker image (digest-pinned) ----------------------------------------
$image = (Get-ProfileValue -Profile $profile -Name 'image')
if ([string]::IsNullOrWhiteSpace($image) -or $image -notmatch '@sha256:') {
    throw 'config/profile is missing the digest-pinned "image" reference (lmsysorg/sglang@sha256:...). Refusing to pull by tag.'
}
if ($null -eq (Get-DockerCli)) { throw 'docker missing (internal error).' }
$localId = Invoke-NativeSafe -FilePath $dockerCli -ArgumentList @('image', 'inspect', '--format', '{{.Id}}', $image) -AllowFail
if ($localId.Code -ne 0) {
    Write-Host "Pulling $image (large; this is a one-time download)..."
    $pull = Invoke-NativeSafe -FilePath $dockerCli -ArgumentList @('pull', $image) -AllowFail
    if ($pull.Code -ne 0) { throw "docker pull failed (exit $($pull.Code))." }
} else {
    Write-Host "Docker image already present: $image"
}

# --- 7. Launch the server container -----------------------------------------
Write-Host ''
Write-Host 'Bootstrap complete. Launching the server container...'
& (Join-Path $PSScriptRoot 'start.ps1')
exit $LASTEXITCODE
