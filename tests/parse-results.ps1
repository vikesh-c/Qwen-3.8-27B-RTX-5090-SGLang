# parse-results.ps1 -- regression test for the llama-benchy parser.
#
#   pwsh ./tests/parse-results.ps1
#
# Feeds a synthetic but schema-faithful llama-benchy 0.4.0 JSON document
# through the SAME functions the runner uses (Read-LlamaBenchyJson,
# Get-LlamaBenchyRungs, Test-RungSet, Convert-RungsToMarkdown) and asserts the
# normalization, ordering, completeness, and Markdown output.
#
# Field names mirror the real --save-result output (verified against a live
# SGLang server): top-level { version, timestamp, latency_mode, latency_ms, model,
# prefix_caching_enabled, max_concurrency, benchmarks: [ { concurrency,
# context_size, prompt_size, response_size, is_context_prefill_phase,
# pp_throughput:{mean,std,values}, tg_throughput:{mean,std,values},
# peak_throughput:{...}, ttfr:{mean,std,values}, ... } ] }.
#
# Runs without Docker, a GPU, or network -- CI-safe.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root (Join-Path 'benchmarks' 'Parse-LlamaBenchyResults.psm1')) -Force

# Synthetic document shaped exactly like llama-benchy --save-result output.
# Three ladder rungs (prompt sizes 4096 / 65536 / 131072), 3 runs each, plus
# one is_context_prefill_phase entry that the parser must skip.
$doc = @{
  version = '0.4.0'
  timestamp = '2026-08-17T00:00:00'
  latency_mode = 'api'
  latency_ms = @()
  model = 'qwen3.8-27b'
  prefix_caching_enabled = $false
  max_concurrency = 1
  benchmarks = @(
    @{ concurrency=1; context_size=4096; prompt_size=4096; response_size=256; is_context_prefill_phase=$false
       pp_throughput=@{ mean=14016.87; std=50.0; values=@(14000.1,14100.5,13950.0) }
       tg_throughput=@{ mean=242.47; std=1.13; values=@(242.4,244.0,241.0) }
       peak_throughput=@{ mean=250.0; std=0.0; values=@(250.0,250.0,250.0) }
       ttfr=@{ mean=120.2; std=1.5; values=@(120.5,118.2,121.9) } }
    @{ concurrency=1; context_size=65536; prompt_size=65536; response_size=256; is_context_prefill_phase=$false
       pp_throughput=@{ mean=5450.0; std=20.0; values=@(5450.0,5480.0,5420.0) }
       tg_throughput=@{ mean=156.3; std=1.0; values=@(156.0,158.0,155.0) }
       peak_throughput=@{ mean=160.0; std=0.0; values=@(160.0,160.0,160.0) }
       ttfr=@{ mean=11500.0; std=15.0; values=@(11500.0,11480.0,11520.0) } }
    @{ concurrency=1; context_size=131072; prompt_size=131072; response_size=256; is_context_prefill_phase=$false
       pp_throughput=@{ mean=3100.0; std=10.0; values=@(3100.0,3120.0,3080.0) }
       tg_throughput=@{ mean=120.5; std=0.8; values=@(120.5,121.0,120.0) }
       peak_throughput=@{ mean=125.0; std=0.0; values=@(125.0,125.0,125.0) }
       ttfr=@{ mean=42000.0; std=50.0; values=@(42000.0,42050.0,41950.0) } }
    # A context-load / prefix-caching phase that the parser must skip.
    @{ concurrency=1; context_size=131072; prompt_size=131072; response_size=0; is_context_prefill_phase=$true
       pp_throughput=@{ mean=1.0; std=0.0; values=@(1.0) }
       tg_throughput=@{ mean=0.0; std=0.0; values=@(0.0) }
       peak_throughput=@{ mean=0.0; std=0.0; values=@(0.0) }
       ttfr=@{ mean=1.0; std=0.0; values=@(1.0) } }
  )
} | ConvertTo-Json -Depth 10

$tmp = Join-Path $env:TEMP "s5090-parse-test-$([guid]::NewGuid().ToString('n')).json"
try {
  $doc | Set-Content -Path $tmp -Encoding UTF8

  $raw = Read-LlamaBenchyJson -Path $tmp
  $rungs = @(Get-LlamaBenchyRungs -Document $raw)

  $fails = 0
  function Assert([bool]$cond, [string]$what) {
    if (-not $cond) { $script:fails++; Write-Host "FAIL: $what" -ForegroundColor Red }
    else { Write-Host "ok:   $what" }
  }

  # Shape: 3 measured rungs (the is_context_prefill_phase entry is skipped)
  Assert ($rungs.Count -eq 3) "three measured rungs (prefill-phase entry skipped), got $($rungs.Count)"
  Assert (($rungs | ForEach-Object { $_.promptTokens }) -join ',' -eq '4096,65536,131072') "rungs sorted by prompt size: 4096,65536,131072"

  # Per-rung normalization
  $r0 = $rungs[0]
  Assert ($r0.prefillTpsMean -eq 14016.87) "rung 4096 prefill mean 14016.87"
  Assert ($r0.decodeTpsMean -eq 242.47) "rung 4096 decode mean 242.47"
  Assert ($r0.prefillTpsRuns.Count -eq 3) "rung 4096 keeps all 3 raw prefill values"
  Assert ($r0.ttfrMsMean -eq 120.2) "rung 4096 ttfr mean 120.2"
  Assert ($r0.runsMeasured -eq 3) "rung 4096 runsMeasured 3"

  # Test-RungSet: passes for a complete 3-run ladder
  $ok = Test-RungSet -Rungs $rungs -ExpectedPrompts @(4096,65536,131072) -ExpectedRuns 3
  Assert ($ok -eq $true) "Test-RungSet accepts a complete 3-run ladder"

  # Test-RungSet: throws when a rung is missing
  $threw = $false
  try { Test-RungSet -Rungs @($rungs[0],$rungs[1]) -ExpectedPrompts @(4096,65536,131072) -ExpectedRuns 3 | Out-Null }
  catch { $threw = $true }
  Assert ($threw) "Test-RungSet throws when a rung is missing"

  # Markdown: both tables + all three contexts appear in each.
  # Note: $md is one multi-line string, so pipe it to nothing -- count matches
  # with [regex]::Matches (Select-String on a single string caps at 1).
  $md = Convert-RungsToMarkdown -Rungs $rungs -Title 'synthetic'
  Assert ($md -match 'Prefill') 'markdown has prefill section'
  Assert ($md -match 'Decode') 'markdown has decode section'
  Assert ([regex]::Matches($md, '4,096').Count -ge 2) 'markdown lists context 4,096 in both tables'
  Assert ([regex]::Matches($md, '65,536').Count -ge 2) 'markdown lists context 65,536 in both tables'
  Assert ([regex]::Matches($md, '131,072').Count -ge 2) 'markdown lists context 131,072 in both tables'

  if ($fails -gt 0) { throw "$fails assertion(s) failed" }
  Write-Host 'PARSE TEST: PASS' -ForegroundColor Green
} finally {
  if (Test-Path $tmp) { Remove-Item $tmp -Force }
}
