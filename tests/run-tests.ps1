# Runs every *.query.pq under tests/queries and tests/perf/queries against
# PQDriverless.mez with PQTest.exe (Microsoft.PowerQuery.SdkTools), timing each
# run, and writes a pass/fail + duration report (markdown + JSON).
#
# PQTest.exe exit codes are not trustworthy (compare exits 0 on a failed
# query), so pass/fail comes from the Status field of the JSON it prints.
#
# Semantics:
#   tests/queries/**   compared against the committed <name>.query.pqout next
#                      to each query. If the .pqout does not exist yet, the run
#                      records it and the test is reported as RECORDED - commit
#                      the file to lock the baseline in.
#   tests/perf/**      never compared: any stale .pqout is deleted first, the
#                      query is timed, and the produced output value is shown
#                      in the report. Pass = query evaluated without error.
#
# Usage: pwsh tests/run-tests.ps1 [-PqTest <path\PQTest.exe>] [-Mez <path>]

param(
    [string]$PqTest,
    [string]$Mez       = (Join-Path $PSScriptRoot "out/PQDriverless.tests.mez"),
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

$LogDir = Join-Path $ReportDir "logs"
New-Item $LogDir -ItemType Directory -Force | Out-Null

# PQTest.exe exit codes are unreliable across the board (errors often exit 0),
# so every step below validates the JSON it prints, never the exit code alone.

# ---- sanity: does the module load, and what does it export? ----
$infoLog = Join-Path $LogDir "_info.log"
& $PqTest info -e $Mez -p > $infoLog 2>&1
$info = Get-Content $infoLog -Raw
try { $infoJson = $info | ConvertFrom-Json } catch { Write-Host $info; throw "PQTest info produced no JSON." }
$broken = @($infoJson) | Where-Object { $_.ErrorStatus }
if ($broken) {
    throw "Extension module failed to compile: $($broken.ErrorStatus -join '; ')"
}

# ---- anonymous credential for the PQDriverless data source kind ----
# CI has no interactive stdin, which puts set-credential into JSON mode, so
# feed it the JSON the documented way: credential-template piped in.
$credQuery = Join-Path $PSScriptRoot "credential.query.pq"
$credLog   = Join-Path $LogDir "_set-credential.log"
$template  = (& $PqTest credential-template -e $Mez -q $credQuery -ak anonymous 2>&1) -join "`n"
if ($template.Trim() -notmatch '^\{') {
    Write-Host $template
    throw "credential-template did not return JSON."
}
$template | & $PqTest set-credential -e $Mez -q $credQuery -p > $credLog 2>&1
$credOut = Get-Content $credLog -Raw
if ($credOut -notmatch '"Status"\s*:\s*"Success"') {
    Write-Host $credOut
    throw "PQTest set-credential did not report Success."
}

$results = @()

function Invoke-Query {
    param([System.IO.FileInfo]$Query, [bool]$IsPerf)

    $pqout = $Query.FullName -replace '\.query\.pq$', '.query.pqout'
    if ($IsPerf -and (Test-Path $pqout)) { Remove-Item $pqout -Force }
    $hadBaseline = Test-Path $pqout

    $log = Join-Path $LogDir ($Query.Directory.Name + "-" + $Query.BaseName + ".log")
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    & $PqTest compare -e $Mez -q $Query.FullName -p > $log 2>&1
    $sw.Stop()

    # PQTest prints a JSON array of test activities; trust its Status field.
    $pqStatus = "Unparsed"
    try {
        $j = Get-Content $log -Raw | ConvertFrom-Json
        $pqStatus = @($j)[0].Status
    } catch { }

    $status =
        if ($pqStatus -ne "Passed")                       { "FAIL ($pqStatus)" }
        elseif ($IsPerf)                                  { "PASS (perf)" }
        elseif (-not $hadBaseline) {
            if (Test-Path $pqout)                         { "RECORDED" }
            else                                          { "FAIL (no output recorded)" }
        }
        else                                              { "PASS" }

    $note = ""
    if ($status -like "FAIL*") {
        try {
            $details = (@($j)[0].Details -replace '\s+', ' ').Trim()
            if ($details.Length -gt 120) { $details = $details.Substring(0, 120) + "..." }
            $note = $details
        } catch { }
    }
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
    Write-Host ("{0,-55} {1,-12} {2,8} ms" -f $r.Test, $r.Status, $r.DurationMs)
    $results += $r
}
foreach ($q in Get-ChildItem (Join-Path $PSScriptRoot "perf/queries") -Recurse -Filter *.query.pq -ErrorAction SilentlyContinue | Sort-Object FullName) {
    $r = Invoke-Query $q $true
    Write-Host ("{0,-55} {1,-12} {2,8} ms   {3}" -f $r.Test, $r.Status, $r.DurationMs, $r.Note)
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
$fails    = @($results | Where-Object { $_.Status -like "FAIL*" })
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
