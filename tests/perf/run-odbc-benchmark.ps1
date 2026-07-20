# ODBC driver vs driverless connector benchmark. First pairing: sqlite3.
#
# Runs the same full-decode query (every cell folded into a non-null count)
# through PQTest.exe twice: once with the repo's driverless Sqlite3.Database
# reader (fixture embedded in PQDriverless.mez), once with Odbc.Query through
# an installed SQLite3 ODBC driver reading the identical file from disk
# (tests/perf/out/bulk.db - the same bytes the mez embeds). Both sides must
# return the same value or the run fails.
#
# A trivial query is timed as well so eval-only figures can be derived from
# the wall-clock medians (PQTest.exe pays ~seconds of process startup per run).
#
# Results land in tests/perf/results/<hostname>.json + .md together with the
# hardware and software environment, so runs from different machines can sit
# side by side in one report.
#
# Prereqs: tests/perf/make_perf_fixtures.py then tests/build-mez.ps1 (fixtures
# are embedded in the mez, so fixtures first), and a 64-bit "SQLite3 ODBC
# Driver" (sqliteodbc) registered in HKLM.
#
# Usage: pwsh tests/perf/run-odbc-benchmark.ps1 [-Runs 5] [-PqTest <path>] [-Mez <path>]

param(
    [int]$Runs        = 5,
    [string]$PqTest,
    [string]$Mez      = (Join-Path (Split-Path $PSScriptRoot -Parent) "out/PQDriverless.mez"),
    [string]$ToolsDir = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ".pqtools"),
    [string]$OutDir   = (Join-Path $PSScriptRoot "results")
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$TestsDir = Split-Path $PSScriptRoot -Parent

if (-not $PqTest) {
    $found = Get-ChildItem $ToolsDir -Recurse -Filter PQTest.exe -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if (-not $found) { throw "PQTest.exe not found under $ToolsDir. nuget install Microsoft.PowerQuery.SdkTools -OutputDirectory $ToolsDir" }
    $PqTest = $found.FullName
}
if (-not (Test-Path $Mez)) { throw "$Mez not found. Run tests/build-mez.ps1 first." }

$DbPath = Join-Path $PSScriptRoot "out/bulk.db"
if (-not (Test-Path $DbPath)) { throw "$DbPath not found. Run tests/perf/make_perf_fixtures.py first." }

$OdbcReg = "HKLM:\SOFTWARE\ODBC\ODBCINST.INI\SQLite3 ODBC Driver"
if (-not (Test-Path $OdbcReg)) { throw "SQLite3 ODBC Driver not registered (64-bit). Install sqliteodbc first." }
$OdbcDll     = (Get-ItemProperty $OdbcReg).Driver
$OdbcVersion = (Get-Item $OdbcDll).VersionInfo.FileVersion

# ---- generated queries (absolute paths, so never committed) ----
$GenDir = Join-Path $PSScriptRoot "odbc/out"
New-Item $GenDir -ItemType Directory -Force | Out-Null

$OdbcQuery = Join-Path $GenDir "sqlite3-odbc-bulk.query.pq"
(Get-Content (Join-Path $PSScriptRoot "odbc/sqlite3-odbc-bulk.query.pq.template") -Raw).
    Replace("__DB_PATH__", (Resolve-Path $DbPath).Path) |
    Set-Content $OdbcQuery -Encoding UTF8

$OverheadQuery = Join-Path $GenDir "overhead.query.pq"
"let one = 1 in one" | Set-Content $OverheadQuery -Encoding UTF8

$DriverlessQuery = Join-Path $PSScriptRoot "queries/sqlite3-bulk.query.pq"

# ---- credentials (anonymous on both sides; validate JSON, not exit codes) ----
function Set-AnonCredential([string]$Query) {
    $template = (& $PqTest credential-template -e $Mez -q $Query -ak anonymous 2>&1) -join "`n"
    if ($template.Trim() -notmatch '^\{') { Write-Host $template; throw "credential-template did not return JSON for $Query." }
    $out = ($template | & $PqTest set-credential -e $Mez -q $Query -p 2>&1) -join "`n"
    if ($out -notmatch '"Status"\s*:\s*"Success"') { Write-Host $out; throw "set-credential failed for $Query." }
}
Set-AnonCredential (Join-Path $TestsDir "credential.query.pq")
Set-AnonCredential $OdbcQuery

# ---- timed runs ----
function Invoke-Timed([string]$Query, [int]$Count) {
    $pqout = $Query -replace '\.query\.pq$', '.query.pqout'
    $times = @(); $value = $null
    for ($i = 0; $i -lt $Count + 1; $i++) {   # +1: first run is an untimed warmup
        if (Test-Path $pqout) { Remove-Item $pqout -Force }
        $sw  = [System.Diagnostics.Stopwatch]::StartNew()
        $raw = (& $PqTest compare -e $Mez -q $Query -p 2>&1) -join "`n"
        $sw.Stop()
        try { $j = @($raw | ConvertFrom-Json)[0] } catch { Write-Host $raw; throw "PQTest printed no JSON for $Query." }
        if ($j.Status -ne "Passed") { Write-Host $raw; throw "PQTest run failed for $Query ($($j.Status))." }
        $value = $j.Output[0].SerializedSource
        if ($i -gt 0) { $times += [math]::Round($sw.Elapsed.TotalMilliseconds) }
        Write-Host ("  {0} run {1}: {2,8} ms{3}" -f (Split-Path $Query -Leaf), $i, [math]::Round($sw.Elapsed.TotalMilliseconds), $(if ($i -eq 0) { " (warmup, untimed)" } else { "" }))
    }
    if (Test-Path $pqout) { Remove-Item $pqout -Force }
    [pscustomobject]@{ RunsMs = $times; MedianMs = ($times | Sort-Object)[[math]::Floor($times.Count / 2)]; Value = $value }
}

Write-Host "Benchmarking ($Runs timed runs each, median reported; 1 warmup run per case)..."
$overhead   = Invoke-Timed $OverheadQuery   $Runs
$driverless = Invoke-Timed $DriverlessQuery $Runs
$odbc       = Invoke-Timed $OdbcQuery       $Runs

if ($driverless.Value -ne $odbc.Value) {
    throw "Output mismatch: driverless=$($driverless.Value) odbc=$($odbc.Value). Not comparable."
}

# ---- environment ----
$cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
$cs    = Get-CimInstance Win32_ComputerSystem
$os    = Get-CimInstance Win32_OperatingSystem
$disk  = try { Get-PhysicalDisk | Where-Object DeviceId -eq ((Get-Partition -DriveLetter ($DbPath[0])).DiskNumber | Select-Object -First 1) | Select-Object -First 1 } catch { $null }
$power = ((powercfg /getactivescheme) -join "") -replace '.*\((.+)\).*', '$1'
$office = try { (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction Stop).VersionToReport } catch { "none" }

$envInfo = [ordered]@{
    machine        = $env:COMPUTERNAME
    timestamp      = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    cpu            = $cpu.Name.Trim()
    cores          = $cpu.NumberOfCores
    logicalCpus    = $cpu.NumberOfLogicalProcessors
    ramGB          = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    disk           = if ($disk) { "$($disk.FriendlyName) ($($disk.MediaType), $($disk.BusType))" } else { "unknown" }
    os             = "$($os.Caption.Trim()) build $($os.BuildNumber)"
    powerPlan      = $power
    pqTestVersion  = (Get-Item $PqTest).VersionInfo.FileVersion
    odbcDriver     = "sqliteodbc $OdbcVersion ($OdbcDll)"
    office         = $office
    fixture        = "bulk.db, $([math]::Round((Get-Item $DbPath).Length / 1MB, 1)) MB, sha256 $((Get-FileHash $DbPath -Algorithm SHA256).Hash.ToLower())"
}

$report = [ordered]@{
    schema      = 1
    method      = [ordered]@{
        runs      = $Runs
        statistic = "median"
        timing    = "wall clock of one PQTest.exe compare per run, warm file cache; includes process startup (see overhead case)"
        query     = "full decode: List.Sum(List.Transform(Table.ToRows(data), List.NonNullCount)) over 200k rows x 4 cols"
    }
    environment = $envInfo
    results     = @(
        [ordered]@{ case = "overhead (trivial query)"; runsMs = $overhead.RunsMs;   medianMs = $overhead.MedianMs;   output = $overhead.Value }
        [ordered]@{ case = "sqlite3 driverless";       runsMs = $driverless.RunsMs; medianMs = $driverless.MedianMs; output = $driverless.Value }
        [ordered]@{ case = "sqlite3 odbc";             runsMs = $odbc.RunsMs;       medianMs = $odbc.MedianMs;       output = $odbc.Value }
    )
    derived     = [ordered]@{
        driverlessEvalMs = $driverless.MedianMs - $overhead.MedianMs
        odbcEvalMs       = $odbc.MedianMs - $overhead.MedianMs
        wallRatio        = [math]::Round($driverless.MedianMs / $odbc.MedianMs, 2)
        evalRatio        = [math]::Round(($driverless.MedianMs - $overhead.MedianMs) / [math]::Max(1, $odbc.MedianMs - $overhead.MedianMs), 2)
    }
}

New-Item $OutDir -ItemType Directory -Force | Out-Null
$jsonPath = Join-Path $OutDir "$($env:COMPUTERNAME).json"
$report | ConvertTo-Json -Depth 4 | Set-Content $jsonPath -Encoding UTF8

$md = [System.Text.StringBuilder]::new()
[void]$md.AppendLine("# ODBC vs driverless: $($env:COMPUTERNAME)")
[void]$md.AppendLine("")
foreach ($k in $envInfo.Keys) { [void]$md.AppendLine("- **$k**: $($envInfo[$k])") }
[void]$md.AppendLine("")
[void]$md.AppendLine("Median of $Runs runs, wall clock per PQTest.exe process, warm cache. Eval = median minus trivial-query overhead.")
[void]$md.AppendLine("")
[void]$md.AppendLine("| case | median (ms) | eval-only (ms) | runs (ms) |")
[void]$md.AppendLine("|---|---:|---:|---|")
foreach ($r in $report.results) {
    $eval = if ($r.case -like "overhead*") { "-" } else { $r.medianMs - $overhead.MedianMs }
    [void]$md.AppendLine("| $($r.case) | $($r.medianMs) | $eval | $($r.runsMs -join ', ') |")
}
[void]$md.AppendLine("")
[void]$md.AppendLine("Wall ratio driverless/odbc: $($report.derived.wallRatio)x - eval-only ratio: $($report.derived.evalRatio)x. Both cases returned $($odbc.Value).")
$mdPath = Join-Path $OutDir "$($env:COMPUTERNAME).md"
$md.ToString() | Set-Content $mdPath -Encoding UTF8

Write-Host ""
Write-Host "Wrote $jsonPath"
Write-Host "Wrote $mdPath"

