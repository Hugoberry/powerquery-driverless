# Runs every *.query.pq under tests/queries and tests/perf/queries against
# PQDriverless.mez with PQTest.exe (Microsoft.PowerQuery.SdkTools), timing each
# run, and writes a pass/fail + duration report (markdown + JSON).
#
# Semantics:
#   tests/queries/**   compared against the committed <name>.query.pqout next
#                      to each query. If the .pqout does not exist yet, the run
#                      records it and the test is reported as RECORDED - commit
#                      the file to lock the baseline in.
#   tests/perf/**      never compared: any stale .pqout is deleted first, the
#                      query is timed, and the produced output value is shown
#                      in the report. Pass = PQTest exits 0.
#
# Usage: pwsh tests/run-tests.ps1 [-PqTest <path\PQTest.exe>] [-Mez <path>]

param(
    [string]$PqTest,
    [string]$Mez       = (Join-Path $PSScriptRoot "out/PQDriverless.mez"),
    [string]$ToolsDir  = (Join-Path (Split-Path $PSScriptRoot -Parent) ".pqtools"),
    [string]$ReportDir = (Join-Path $PSScriptRoot "out")
)

$ErrorActionPreference = "Stop"

if (-not $PqTest) {
    $found = Get-ChildItem $ToolsDir -Recurse -Filter PQTest.exe -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if (-not $found) { throw "PQTest.exe not found under $ToolsDir. nuget install Microsoft.PowerQuery.SdkTools -OutputDirectory $ToolsDir" }
    $PqTest = $found.FullName
}
if (-not (Test-Path $Mez)) { throw "$Mez not found. Run tests/build-mez.ps1 first." }

New-Item (Join-Path $ReportDir "logs") -ItemType Directory -Force | Out-Null

$results = @()

function Invoke-Query {
    param([System.IO.FileInfo]$Query, [bool]$IsPerf)

    $pqout = $Query.FullName -replace '\.query\.pq$', '.query.pqout'
    if ($IsPerf -and (Test-Path $pqout)) { Remove-Item $pqout -Force }
    $hadBaseline = Test-Path $pqout

    $log = Join-Path $ReportDir ("logs/" + $Query.BaseName + ".log")
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    & $PqTest compare -e $Mez -q $Query.FullName -p *> $log
    $exit = $LASTEXITCODE
    $sw.Stop()

    $status =
        if ($exit -ne 0)          { "FAIL" }
        elseif ($IsPerf)          { "PASS (perf)" }
        elseif (-not $hadBaseline){ "RECORDED" }
        else                      { "PASS" }

    $note = ""
    if ($IsPerf -and (Test-Path $pqout)) {
        $note = ((Get-Content $pqout -Raw) -replace '\s+', ' ').Trim()
        if ($note.Length -gt 120) { $note = $note.Substring(0, 120) + "..." }
    }

    [pscustomobject]@{
        Test       = ($Query.FullName.Substring($PSScriptRoot.Length + 1) -replace '\\', '/')
        Status     = $status
        DurationMs = [math]::Round($sw.Elapsed.TotalMilliseconds)
        Note       = $note
    }
}

foreach ($q in Get-ChildItem (Join-Path $PSScriptRoot "queries") -Recurse -Filter *.query.pq | Sort-Object FullName) {
    $r = Invoke-Query $q $false
    Write-Host ("{0,-55} {1,-10} {2,8} ms" -f $r.Test, $r.Status, $r.DurationMs)
    $results += $r
}
foreach ($q in Get-ChildItem (Join-Path $PSScriptRoot "perf/queries") -Recurse -Filter *.query.pq -ErrorAction SilentlyContinue | Sort-Object FullName) {
    $r = Invoke-Query $q $true
    Write-Host ("{0,-55} {1,-10} {2,8} ms   {3}" -f $r.Test, $r.Status, $r.DurationMs, $r.Note)
    $results += $r
}

# ---- report ----
$json = Join-Path $ReportDir "report.json"
$results | ConvertTo-Json -Depth 3 | Set-Content $json -Encoding UTF8

$md = [System.Text.StringBuilder]::new()
[void]$md.AppendLine("## PQTest results")
[void]$md.AppendLine("")
[void]$md.AppendLine("| Test | Status | Duration (ms) | Output |")
[void]$md.AppendLine("|---|---|---:|---|")
foreach ($r in $results) {
    [void]$md.AppendLine("| $($r.Test) | $($r.Status) | $($r.DurationMs) | $($r.Note) |")
}
$fails    = @($results | Where-Object Status -eq "FAIL")
$recorded = @($results | Where-Object Status -eq "RECORDED")
[void]$md.AppendLine("")
[void]$md.AppendLine("$($results.Count) tests, $($fails.Count) failed, $($recorded.Count) newly recorded.")
$mdPath = Join-Path $ReportDir "report.md"
$md.ToString() | Set-Content $mdPath -Encoding UTF8
if ($env:GITHUB_STEP_SUMMARY) { $md.ToString() | Add-Content $env:GITHUB_STEP_SUMMARY }

Write-Host ""
Write-Host "Report: $mdPath"
if ($fails.Count -gt 0) {
    Write-Host "FAILED tests: $($fails.Test -join ', ')" -ForegroundColor Red
    exit 1
}
