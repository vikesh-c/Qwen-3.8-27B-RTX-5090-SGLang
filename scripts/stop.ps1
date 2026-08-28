# stop.ps1 -- stop the SGLang server container (exact name match only).
#
#   .\scripts\stop.ps1
#
# Removes only the container named in config (default sglang-qwen38-lmhead4).
# Never stops unrelated containers, and never deletes model/runtime data.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$prof = Get-RecipeProfile
$profile = $prof.Profile
$container = (Get-ProfileValue -Profile $profile -Name 'containerName' -Fallback 'sglang-qwen38-lmhead4')

$state = Get-DockerContainerState -Name $container
if ($null -eq $state) {
    Write-Host "Container '$container' is not present. Nothing to stop."
    exit 0
}

Write-Host "Stopping container '$container' (status: $($state.Status))..."
$res = Invoke-NativeSafe -FilePath 'docker' -ArgumentList @('rm', '-f', $container) -AllowFail
if ($res.Code -ne 0) {
    throw "docker rm -f '$container' failed (exit $($res.Code))."
}
Write-Host "Container '$container' removed."
exit 0
