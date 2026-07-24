# Old-vs-new A/B for the sqlite3 DecodeValue integer path (commit e3350e5),
# on the integer-heavy fixture bulk-int.db (serial types 1..6, which the
# default bulk.db never exercises). Times the full-decode fold against one mez
# and reads the value checksum once. Run it against the new-code mez and the
# old-code mez (built by swapping sqlite3/Sqlite3.Database.pq to e3350e5^),
# same session, to isolate the DecodeValue change from machine drift.
#
# Usage: pwsh tests/perf/ab-sqlite-intdecode.ps1 -Mez <path> -Tag new [-Runs 5]

param(
    [Parameter(Mandatory)][string]$Mez,
    [Parameter(Mandatory)][string]$Tag,
    [int]$Runs = 5,
    [string]$PqTest,
    [string]$ToolsDir = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ".pqtools"),
    [string]$OutDir   = (Join-Path $PSScriptRoot "results")
)
$ErrorActionPreference = "Stop"
$TestsDir = Split-Path $PSScriptRoot -Parent

if (-not $PqTest) {
    $PqTest = Get-ChildItem $ToolsDir -Recurse -Filter PQTest.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if (-not $PqTest) { throw "PQTest.exe not found under $ToolsDir." }
}
if (-not (Test-Path $Mez)) { throw "$Mez not found." }

$GenDir = Join-Path $PSScriptRoot "out-gen"
New-Item $GenDir -ItemType Directory -Force | Out-Null
$OverheadQuery = Join-Path $GenDir "overhead.query.pq"
"let one = 1 in one" | Set-Content $OverheadQuery -Encoding UTF8

function Set-AnonCredential([string]$Query) {
    $template = (& $PqTest credential-template -e $Mez -q $Query -ak anonymous 2>&1) -join "`n"
    if ($template.Trim() -notmatch '^\{') { Write-Host $template; throw "credential-template failed for $Query." }
    $out = ($template | & $PqTest set-credential -e $Mez -q $Query -p 2>&1) -join "`n"
    if ($out -notmatch '"Status"\s*:\s*"Success"') { Write-Host $out; throw "set-credential failed for $Query." }
}
Set-AnonCredential (Join-Path $TestsDir "credential.query.pq")

function Invoke-Timed([string]$Query, [int]$Count) {
    $pqout = $Query -replace '\.query\.pq$', '.query.pqout'
    $times = @(); $value = $null
    for ($i = 0; $i -lt $Count + 1; $i++) {
        if (Test-Path $pqout) { Remove-Item $pqout -Force }
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $raw = (& $PqTest compare -e $Mez -q $Query -p 2>&1) -join "`n"
        $sw.Stop()
        try { $j = @($raw | ConvertFrom-Json)[0] } catch { Write-Host $raw; throw "no JSON for $Query." }
        if ($j.Status -ne "Passed") { Write-Host $raw; throw "run failed for $Query ($($j.Status))." }
        $value = $j.Output[0].SerializedSource
        if ($i -gt 0) { $times += [math]::Round($sw.Elapsed.TotalMilliseconds) }
        Write-Host ("  {0} [{1}] run {2}: {3,8} ms{4}" -f (Split-Path $Query -Leaf), $Tag, $i, [math]::Round($sw.Elapsed.TotalMilliseconds), $(if ($i -eq 0) { " (warmup)" } else { "" }))
    }
    if (Test-Path $pqout) { Remove-Item $pqout -Force }
    [pscustomobject]@{ RunsMs = $times; MedianMs = ($times | Sort-Object)[[math]::Floor($times.Count / 2)]; Value = $value }
}

Write-Host "A/B [$Tag] mez=$Mez runs=$Runs"
$overhead = Invoke-Timed $OverheadQuery $Runs
$decode   = Invoke-Timed (Join-Path $PSScriptRoot "queries/sqlite3-int-decode.query.pq") $Runs
$checksum = Invoke-Timed (Join-Path $PSScriptRoot "queries/sqlite3-int-checksum.query.pq") 1   # correctness, once

$evalMs = $decode.MedianMs - $overhead.MedianMs
$out = [ordered]@{
    tag          = $Tag
    mez          = $Mez
    timestamp    = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    runs         = $Runs
    overheadMs   = $overhead.MedianMs
    decode       = [ordered]@{ runsMs = $decode.RunsMs; medianMs = $decode.MedianMs; evalMs = $evalMs; value = $decode.Value }
    checksumValue = $checksum.Value
}
New-Item $OutDir -ItemType Directory -Force | Out-Null
$jsonPath = Join-Path $OutDir "ab-intdecode-$Tag.json"
$out | ConvertTo-Json -Depth 4 | Set-Content $jsonPath -Encoding UTF8
Write-Host ""
Write-Host ("[$Tag] decode eval median = {0} ms (fold={1}); checksum={2}" -f $evalMs, $decode.Value, $checksum.Value)
Write-Host "Wrote $jsonPath"
