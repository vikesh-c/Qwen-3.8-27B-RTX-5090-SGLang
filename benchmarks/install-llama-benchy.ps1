# install-llama-benchy.ps1 -- make the pinned benchmark tool available.
#
#   .\benchmarks\install-llama-benchy.ps1
#
# llama-benchy (https://github.com/eugr/llama-benchy) is run through uvx, so
# there is nothing to install in the repo: this script checks that uv/uvx
# exist (installing uv via pip if not) and that the pinned version resolves.
# The first real bench run may take a few extra seconds while uvx fetches the
# tool and its tokenizer dependencies once.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\common.ps1')

$PinnedSpec = 'llama-benchy==0.4.0'

function Invoke-NativeSafeChecked {
    param([string]$FilePath, [string[]]$ArgumentList)
    $res = Invoke-NativeSafe -FilePath $FilePath -ArgumentList $ArgumentList -AllowFail
    if ($res.Code -ne 0) { throw "$FilePath $($ArgumentList -join ' ') failed (exit $($res.Code))." }
    return $res
}

# --- uv / uvx ----------------------------------------------------------------
$uvx = Get-Command uvx -ErrorAction SilentlyContinue
if ($null -eq $uvx) {
    Write-Host 'uvx not found -- installing uv (provides uvx) via pip...'
    $pip = $null
    foreach ($candidate in @('pip', 'python')) {
        if (Test-CommandAvailable -Name $candidate) { $pip = $candidate; break }
    }
    if ($null -eq $pip) { throw 'Neither uvx nor pip was found. Install Python 3.10+ (with pip) or uv, then re-run.' }
    $args = @('install', '-U', 'uv')
    if ($pip -eq 'python') { $args = @('-m', 'pip', 'install', '-U', 'uv') }
    Invoke-NativeSafeChecked -FilePath $pip -ArgumentList $args | Out-Null
    $uvx = Get-Command uvx -ErrorAction SilentlyContinue
    if ($null -eq $uvx) { throw 'uv installed, but uvx is still not on PATH. Restart your shell and re-run.' }
}
Write-Host "uvx: $($uvx.Source)"

# --- pinned version resolves --------------------------------------------------
$res = Invoke-NativeSafeChecked -FilePath $uvx.Source -ArgumentList @(
    '--from', $PinnedSpec, 'llama-benchy', '--version')
$versionLine = @($res.Lines | Where-Object { $_ -match 'llama-benchy' } | Select-Object -First 1)
if ($versionLine.Count -eq 0 -or $versionLine[0] -notmatch '0\.4\.0') {
    throw "Expected pinned llama-benchy 0.4.0 but got: $($versionLine -join ' ')"
}
Write-Host "$($versionLine[0])"
Write-Host 'llama-benchy is ready. Run:  .\benchmarks\bench.ps1'
exit 0
