# Parse-LlamaBenchyResults.psm1 -- shared parser for llama-benchy 0.4.0 JSON.
#
# Used by benchmarks\bench.ps1 and tests\parse-results.ps1 so the runner and
# the regression test exercise the exact same logic.
#
# llama-benchy's --format JSON emits:
#   { version, timestamp, latency_mode, latency_ms, model,
#     prefix_caching_enabled, max_concurrency,
#     benchmarks: [ { concurrency, context_size, prompt_size, response_size,
#                     is_context_prefill_phase,
#                     pp_throughput:  { mean, std, values[] },
#                     pp_req_throughput: {...},
#                     tg_throughput:  { mean, std, values[] },
#                     tg_req_throughput: {...},
#                     peak_throughput: {...}, peak_req_throughput: {...},
#                     ttfr:  { mean, std, values[] },
#                     est_ppt: {...}, e2e_ttft: {...}, ... } ] }
#
# One benchmark entry per (context depth, prompt size, response size) shape.
# Every entry carries BOTH the cold-prefill rate (pp_throughput) and the
# post-prefill decode rate (tg_throughput) for the same context shape -- a
# single ladder run therefore yields both tables.

function Read-LlamaBenchyJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Result file not found: $Path" }
    $raw = [IO.File]::ReadAllText($Path)
    # Strip a UTF-8 BOM by code point. Do NOT use $raw.StartsWith([char]0xFEFF):
    # PowerShell 5.1 stringifies the BOM char to "" so StartsWith is always true
    # and the (then-applied) Substring(1) would delete the opening '{'.
    if ($raw.Length -gt 0 -and [int]$raw[0] -eq 0xFEFF) { $raw = $raw.Substring(1) }
    return $raw | ConvertFrom-Json
}

function Get-LlamaBenchyRungs {
    <#
    .SYNOPSIS
      Normalize llama-benchy JSON into one ordered record per rung.
    .DESCRIPTION
      A rung is keyed by its prompt size (the context depth in this recipe is
      0, so prompt size uniquely identifies the rung). Each record exposes the
      mean/std/dev of the per-run measurements plus the raw per-run values, so
      receipts keep the full distribution, not just the average.
    #>
    param([Parameter(Mandatory)][object]$Document)

    $rungs = [System.Collections.Generic.List[object]]::new()
    foreach ($b in @($Document.benchmarks)) {
        if ([bool]$b.PSObject.Properties['is_context_prefill_phase'].Value) {
            # A prefix-caching context-load phase, not a measured rung. Skip.
            continue
        }
        $rungs.Add([ordered]@{
            promptTokens      = [int]$b.prompt_size
            contextSize       = [int]$b.context_size
            responseSize      = [int]$b.response_size
            concurrency       = [int]$b.concurrency
            prefillTpsMean    = [double]$b.pp_throughput.mean
            prefillTpsStd     = [double]$b.pp_throughput.std
            prefillTpsRuns    = @($b.pp_throughput.values | ForEach-Object { [double]$_ })
            decodeTpsMean     = [double]$b.tg_throughput.mean
            decodeTpsStd      = [double]$b.tg_throughput.std
            decodeTpsRuns     = @($b.tg_throughput.values | ForEach-Object { [double]$_ })
            peakTpsMean       = [double]$b.peak_throughput.mean
            ttfrMsMean        = [double]$b.ttfr.mean
            ttfrMsStd         = [double]$b.ttfr.std
            runsMeasured      = @($b.tg_throughput.values).Count
        })
    }
    return $rungs | Sort-Object -Property @{ Expression = { $_.promptTokens } }
}

function Test-RungSet {
    <#
    .SYNOPSIS
      Verify a ladder receipt is complete and self-consistent.
    .PARAMETER ExpectedPrompts
      The exact prompt sizes the ladder must contain, in order.
    .PARAMETER ExpectedRuns
      The number of measured runs each rung must carry (e.g. 3).
    .OUTPUTS
      Throws with a descriptive message on any violation; returns $true when
      the receipt is complete.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Rungs,
        [Parameter(Mandatory)][int[]]$ExpectedPrompts,
        [int]$ExpectedRuns = 3
    )

    if ($Rungs.Count -ne $ExpectedPrompts.Count) {
        throw "Ladder is incomplete: got $($Rungs.Count) rungs, expected $($ExpectedPrompts.Count)."
    }
    for ($i = 0; $i -lt $ExpectedPrompts.Count; $i++) {
        $rung = $Rungs[$i]
        if ([int]$rung.promptTokens -ne $ExpectedPrompts[$i]) {
            throw "Rung $i prompt size mismatch: got $($rung.promptTokens), expected $($ExpectedPrompts[$i])."
        }
        if ([int]$rung.runsMeasured -ne $ExpectedRuns) {
            throw "Rung $($rung.promptTokens) measured $($rung.runsMeasured) runs, expected $ExpectedRuns."
        }
        if ([double]$rung.prefillTpsMean -le 0 -or [double]$rung.decodeTpsMean -le 0) {
            throw "Rung $($rung.promptTokens) has a non-positive throughput (prefill=$($rung.prefillTpsMean), decode=$($rung.decodeTpsMean))."
        }
    }
    return $true
}

function Convert-RungsToMarkdown {
    <#
    .SYNOPSIS
      Render parsed rungs as the README's two tables (prefill + decode).
    #>
    param(
        [Parameter(Mandatory)][object[]]$Rungs,
        [string]$Title = 'llama-benchy ladder'
    )

    $singleRun = @($Rungs | Where-Object { $_.runsMeasured -ne 1 }).Count -eq 0

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("## $Title")
    $lines.Add('')
    if ($singleRun) {
        $lines.Add('**Prefill** (cold, unique prompts -- 1 run per context):')
    } else {
        $lines.Add('**Prefill** (cold, unique prompts -- mean of the measured runs):')
    }
    $lines.Add('')
    if ($singleRun) {
        $lines.Add('| Context | tok/s | Time to first token |')
        $lines.Add('|---:|---:|---:|')
    } else {
        $lines.Add('| Context | tok/s | Std | Time to first token |')
        $lines.Add('|---:|---:|---:|---:|')
    }
    foreach ($r in $Rungs) {
        $ttftS = [math]::Round([double]$r.ttfrMsMean / 1000.0, 1)
        if ($singleRun) {
            $ppRow = "| {0:N0} | {1:N1} | {2:N1} s |" -f $r.promptTokens, $r.prefillTpsMean, $ttftS
        } else {
            $ppRow = "| {0:N0} | {1:N1} | {2:N1} | {3:N1} s |" -f $r.promptTokens, $r.prefillTpsMean, $r.prefillTpsStd, $ttftS
        }
        $lines.Add($ppRow)
    }
    $lines.Add('')
    if ($singleRun) {
        $lines.Add('**Decode** (exact output length, 1 run per context, DSpark acceptance workload-sensitive):')
        $lines.Add('')
        $lines.Add('| Context | tok/s |')
        $lines.Add('|---:|---:|')
    } else {
        $lines.Add('**Decode** (exact output length, DSpark acceptance workload-sensitive):')
        $lines.Add('')
        $lines.Add('| Context | tok/s | Std |')
        $lines.Add('|---:|---:|---:|')
    }
    foreach ($r in $Rungs) {
        if ($singleRun) {
            $tgRow = "| {0:N0} | {1:N1} |" -f $r.promptTokens, $r.decodeTpsMean
        } else {
            $tgRow = "| {0:N0} | {1:N1} | {2:N1} |" -f $r.promptTokens, $r.decodeTpsMean, $r.decodeTpsStd
        }
        $lines.Add($tgRow)
    }
    return ($lines -join [Environment]::NewLine)
}

Export-ModuleMember -Function Read-LlamaBenchyJson, Get-LlamaBenchyRungs, Test-RungSet, Convert-RungsToMarkdown
