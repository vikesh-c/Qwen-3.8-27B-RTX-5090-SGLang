[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$errors = New-Object System.Collections.Generic.List[string]
function Add-Error([string]$Message) { $errors.Add($Message) }
function Read-Json([string]$Path) {
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { Add-Error "JSON parse failed: $Path"; return $null }
}

Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 -File | ForEach-Object {
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { Add-Error "PowerShell parse failed: $($_.FullName)" }
}
Get-ChildItem -LiteralPath $root -Recurse -Filter *.json -File | ForEach-Object { Read-Json $_.FullName | Out-Null }

$profilePath = Join-Path $root 'config\profile.example.json'
$profile = Read-Json $profilePath
if ($profile) {
    if ($profile.schema -ne 1 -or $profile.profile -ne 'qwen3.8-27b-rtx5090-sglang') { Add-Error 'Profile identity/schema is incorrect.' }
    if ($profile.host -ne '127.0.0.1' -or $profile.parallel -ne 1) { Add-Error 'Profile must remain loopback-only and single-slot.' }
    if ($profile.context -ne 163840 -or $profile.maxContext -ne 163840) { Add-Error 'Profile context must remain exactly 163840.' }
    if ($profile.kvCacheDtype -ne 'fp8_e4m3') { Add-Error 'Profile KV cache dtype must remain fp8_e4m3.' }
    if ($profile.attentionBackend -ne 'flashinfer') { Add-Error 'Profile attention backend must remain flashinfer.' }
    if ($profile.disableRadixCache -ne $true -or $profile.maxRunningRequests -ne 1) { Add-Error 'Profile must remain radix-cache-disabled and single-request.' }
    if ($profile.prefillMaxRequests -ne 1 -or $profile.schedulePolicy -ne 'fcfs' -or $profile.sleepOnIdle -ne $true) { Add-Error 'Profile must remain single-prefill, FCFS, and sleep-on-idle.' }
    if ($profile.requestWaitingTimeoutSeconds -ne -1 -or $profile.requestRunningTimeoutSeconds -ne -1) { Add-Error 'Profile request timeouts must remain unlimited (-1).'}
    $spec = $profile.speculative
    if ($spec.enabled -ne $true -or $spec.algorithm -ne 'DSPARK' -or $spec.draftQuantization -ne 'fp8' -or $spec.numSteps -ne 7 -or $spec.eagleTopk -ne 1 -or $spec.numDraftTokens -ne 8) {
        Add-Error 'Bundled DSpark speculative profile changed.'
    }
    if ($profile.image -notmatch '@sha256:[A-Fa-f0-9]{64}$') { Add-Error 'Profile image must be digest-pinned (repo@sha256:64hex).' }
    foreach ($name in @('modelRelativePath','draftRelativePath','logRelativePath','stateRelativePath')) {
        $value = [string]$profile.$name
        if ([IO.Path]::IsPathRooted($value) -or $value -match '(^|[\\\\/])\\.\\.([\\\\/]|$)') { Add-Error "Profile path is not portable: $name" }
    }
    $art = $profile.artifacts
    if ([string]$art.modelRevision -notmatch '^[A-Fa-f0-9]{40}$') { Add-Error 'Profile model revision is not a 40-hex git revision.' }
    if ([string]$art.draftRevision -notmatch '^[A-Fa-f0-9]{40}$') { Add-Error 'Profile draft revision is not a 40-hex git revision.' }
    if ([string]$art.imageDigest -notmatch '^sha256:[A-Fa-f0-9]{64}$') { Add-Error 'Profile image digest is not sha256:64hex.' }
}

$windowsUserPathPattern = '(?i)' + [regex]::Escape(('C:' + '\' + 'Users' + '\'))
$unixUserPathPattern = '(?i)' + [regex]::Escape(('/' + 'home' + '/')) + '|' + [regex]::Escape(('/' + 'root' + '/'))
$forbidden = @(
    '(?i)ghp_[A-Za-z0-9]{20,}',
    '(?i)github_pat_[A-Za-z0-9_]{20,}',
    '(?i)gho_[A-Za-z0-9]{20,}',
    '(?i)BEGIN (RSA|OPENSSH|PRIVATE) KEY',
    $windowsUserPathPattern,
    $unixUserPathPattern
)
$textExtensions = @('.ps1','.json','.md','.yml','.yaml','.txt','.license','')
$files = Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object { $_.FullName -notlike "$(Join-Path $root '.git')\*" -and $_.FullName -notlike "$(Join-Path $root 'logs')\*" -and $_.FullName -notlike "$(Join-Path $root 'state')\*" -and $_.FullName -notlike "$(Join-Path $root 'local')\*" }
foreach ($item in $files) {
    $relative = $item.FullName.Substring($root.Length + 1).Replace('/','\')
    if ($relative -eq 'scripts\validate.ps1') { continue }
    if ($item.Length -gt 5242880) { Add-Error "Unexpectedly large file: $relative"; continue }
    if ($relative -match '(?i)(^|\\)(profile\.json|\.env($|\.)|.*\.(key|secret|token)$)') { Add-Error "Local-only secret/config file present: $relative"; continue }
    if ($item.Extension.ToLowerInvariant() -in @('.gguf','.exe','.dll','.zip','.log','.bin')) { Add-Error "Binary/log artifact present: $relative"; continue }
    if ($item.Extension.ToLowerInvariant() -notin $textExtensions -and $item.Name -ne '.gitignore') { continue }
    $text = Get-Content -LiteralPath $item.FullName -Raw
    foreach ($pattern in $forbidden) { if ($text -match $pattern) { Add-Error "Forbidden pattern in $relative"; break } }
}

if (Test-Path -LiteralPath (Join-Path $root '.git') -PathType Container) {
    $gitStdout = [IO.Path]::GetTempFileName()
    $gitStderr = [IO.Path]::GetTempFileName()
    try {
        $gitProc = Start-Process -FilePath 'git.exe' -ArgumentList @('-C', $root, 'diff', '--check') -RedirectStandardOutput $gitStdout -RedirectStandardError $gitStderr -Wait -PassThru -WindowStyle Hidden
        if ($gitProc.ExitCode -ne 0) { Add-Error 'git diff --check failed.' }
    } finally {
        Remove-Item -LiteralPath $gitStdout,$gitStderr -Force -ErrorAction SilentlyContinue
    }
}
if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ }
    exit 1
}
Write-Output 'Repository validation passed.'
