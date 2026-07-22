# ODBC driver vs driverless connector benchmark.
#
# For each pairing below, the same full-decode query (every cell folded into a
# non-null count) runs through PQTest.exe twice: once with the repo's
# driverless reader (fixture embedded in PQDriverless.tests.mez), once with
# Odbc.Query through the installed driver reading the identical file from
# disk. Both sides must return the same value or the pairing fails. Pairings
# whose driver or fixture is missing on this machine are recorded as skipped,
# so partial environments (e.g. no Office) still produce a valid results file.
#
# A trivial query is timed as well so eval-only figures can be derived from
# the wall-clock medians (PQTest.exe pays ~seconds of process startup per run).
#
# Results land in tests/perf/results/<hostname>.json + .md together with the
# hardware and software environment, so runs from different machines can sit
# side by side in one report.
#
# Prereqs, in order (fixtures are embedded in the mez, so fixtures first):
#   python tests/perf/make_perf_fixtures.py       (bulk.db, bulk.dbf, ...)
#   pwsh tests/perf/make_ace_fixtures.ps1          (bulk-ace.*; needs Office)
#   pwsh tests/build-mez.ps1
# Drivers: sqliteodbc 64-bit for sqlite3; ACE (installed with 64-bit Office)
# for xls/xlsb/access/dbf.
#
# Usage: pwsh tests/perf/run-odbc-benchmark.ps1 [-Runs 5] [-PqTest <path>] [-Mez <path>]

param(
    [int]$Runs        = 5,
    # Distinguishes runs at non-default fixture scales: results are written to
    # <hostname>-<label>.json+md instead of <hostname>.json+md.
    [string]$Label    = "",
    [string]$PqTest,
    [string]$Mez      = (Join-Path (Split-Path $PSScriptRoot -Parent) "out/PQDriverless.tests.mez"),
    [string]$ToolsDir = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ".pqtools"),
    [string]$OutDir   = (Join-Path $PSScriptRoot "results")
)

$ErrorActionPreference = "Stop"

$TestsDir = Split-Path $PSScriptRoot -Parent
$PerfOut  = Join-Path $PSScriptRoot "out"

if (-not $PqTest) {
    $found = Get-ChildItem $ToolsDir -Recurse -Filter PQTest.exe -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if (-not $found) { throw "PQTest.exe not found under $ToolsDir. nuget install Microsoft.PowerQuery.SdkTools -OutputDirectory $ToolsDir" }
    $PqTest = $found.FullName
}
if (-not (Test-Path $Mez)) { throw "$Mez not found. Run tests/build-mez.ps1 first." }

# name, driverless query (repo-relative to tests/perf), odbc template, fixture
# file the odbc side reads, and the HKLM ODBCINST.INI driver it needs.
$Pairings = @(
    @{ Name = "sqlite3"; Driverless = "queries/sqlite3-bulk.query.pq";              Template = "odbc/sqlite3.odbc.query.pq.template";    Fixture = "bulk.db";        DriverKey = "SQLite3 ODBC Driver" }
    @{ Name = "xlsb";    Driverless = "odbc/pairings/xlsb-ace.driverless.query.pq"; Template = "odbc/xlsb-ace.odbc.query.pq.template";   Fixture = "bulk-ace.xlsb";  DriverKey = "Microsoft Excel Driver (*.xls, *.xlsx, *.xlsm, *.xlsb)" }
    @{ Name = "xls";     Driverless = "odbc/pairings/xls-ace.driverless.query.pq";  Template = "odbc/xls-ace.odbc.query.pq.template";    Fixture = "bulk-ace.xls";   DriverKey = "Microsoft Excel Driver (*.xls, *.xlsx, *.xlsm, *.xlsb)" }
    @{ Name = "access";  Driverless = "odbc/pairings/access-ace.driverless.query.pq"; Template = "odbc/access-ace.odbc.query.pq.template"; Fixture = "bulk-ace.accdb"; DriverKey = "Microsoft Access Driver (*.mdb, *.accdb)" }
    @{ Name = "dbf";     Driverless = "queries/dbf-bulk.query.pq";                  Template = "odbc/dbf.odbc.query.pq.template";        Fixture = "bulk.dbf";       DriverKey = "Microsoft Access dBASE Driver (*.dbf, *.ndx, *.mdx)" }
)

function Get-DriverVersion([string]$Key) {
    $reg = "HKLM:\SOFTWARE\ODBC\ODBCINST.INI\$Key"
    if (-not (Test-Path $reg)) { return $null }
    $dll = (Get-ItemProperty $reg).Driver
    "{0} ({1})" -f (Get-Item $dll).VersionInfo.FileVersion, $dll
}

# ---- generated queries (absolute paths, so never committed) ----
$GenDir = Join-Path $PSScriptRoot "odbc/out"
New-Item $GenDir -ItemType Directory -Force | Out-Null

$OverheadQuery = Join-Path $GenDir "overhead.query.pq"
"let one = 1 in one" | Set-Content $OverheadQuery -Encoding UTF8

# ---- credentials (anonymous on both sides; validate JSON, not exit codes) ----
function Set-AnonCredential([string]$Query) {
    $template = (& $PqTest credential-template -e $Mez -q $Query -ak anonymous 2>&1) -join "`n"
    if ($template.Trim() -notmatch '^\{') { Write-Host $template; throw "credential-template did not return JSON for $Query." }
    $out = ($template | & $PqTest set-credential -e $Mez -q $Query -p 2>&1) -join "`n"
    if ($out -notmatch '"Status"\s*:\s*"Success"') { Write-Host $out; throw "set-credential failed for $Query." }
}
Set-AnonCredential (Join-Path $TestsDir "credential.query.pq")

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
$overhead = Invoke-Timed $OverheadQuery $Runs

$pairingResults = @()
foreach ($p in $Pairings) {
    $fixturePath = Join-Path $PerfOut $p.Fixture
    $driverVer   = Get-DriverVersion $p.DriverKey
    if (-not $driverVer -or -not (Test-Path $fixturePath)) {
        $why = if (-not $driverVer) { "driver '$($p.DriverKey)' not installed" } else { "fixture $($p.Fixture) missing" }
        Write-Host "[$($p.Name)] SKIPPED: $why"
        $pairingResults += [ordered]@{ name = $p.Name; status = "skipped"; reason = $why }
        continue
    }

    $pairRuns = if ($p.ContainsKey("Runs")) { $p.Runs } else { $Runs }
    Write-Host "[$($p.Name)] ($pairRuns timed runs)"
    $odbcQuery = Join-Path $GenDir "$($p.Name).odbc.query.pq"
    (Get-Content (Join-Path $PSScriptRoot $p.Template) -Raw).
        Replace("__PERF_OUT__", (Resolve-Path $PerfOut).Path) |
        Set-Content $odbcQuery -Encoding UTF8
    Set-AnonCredential $odbcQuery

    $driverless = Invoke-Timed (Join-Path $PSScriptRoot $p.Driverless) $pairRuns
    $odbc       = Invoke-Timed $odbcQuery $pairRuns

    if ($driverless.Value -ne $odbc.Value) {
        throw "[$($p.Name)] output mismatch: driverless=$($driverless.Value) odbc=$($odbc.Value). Not comparable."
    }

    $dlEval = $driverless.MedianMs - $overhead.MedianMs
    $odEval = [math]::Max(1, $odbc.MedianMs - $overhead.MedianMs)
    $pairingResults += [ordered]@{
        name       = $p.Name
        status     = "measured"
        runs       = $pairRuns
        fixture    = "$($p.Fixture), $([math]::Round((Get-Item $fixturePath).Length / 1MB, 1)) MB, sha256 $((Get-FileHash $fixturePath -Algorithm SHA256).Hash.ToLower())"
        output     = $odbc.Value
        odbcDriver = $driverVer
        driverless = [ordered]@{ runsMs = $driverless.RunsMs; medianMs = $driverless.MedianMs; evalMs = $dlEval }
        odbc       = [ordered]@{ runsMs = $odbc.RunsMs;       medianMs = $odbc.MedianMs;       evalMs = $odbc.MedianMs - $overhead.MedianMs }
        wallRatio  = [math]::Round($driverless.MedianMs / $odbc.MedianMs, 2)
        evalRatio  = [math]::Round($dlEval / $odEval, 2)
    }
}

# ---- environment ----
$cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
$cs    = Get-CimInstance Win32_ComputerSystem
$os    = Get-CimInstance Win32_OperatingSystem
$disk  = try { Get-PhysicalDisk | Where-Object DeviceId -eq ((Get-Partition -DriveLetter ($PerfOut[0])).DiskNumber | Select-Object -First 1) | Select-Object -First 1 } catch { $null }
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
    office         = $office
}

$report = [ordered]@{
    schema      = 2
    method      = [ordered]@{
        label     = $Label
        runs      = $Runs
        statistic = "median"
        timing    = "wall clock of one PQTest.exe compare per run, warm file cache; includes process startup (see overheadMs)"
        query     = "full decode: List.Sum(List.Transform(Table.ToRows(t), List.NonNullCount)); eval = median - overhead median"
    }
    environment = $envInfo
    overheadMs  = [ordered]@{ runsMs = $overhead.RunsMs; medianMs = $overhead.MedianMs }
    pairings    = $pairingResults
}

New-Item $OutDir -ItemType Directory -Force | Out-Null
$baseName = if ($Label) { "$($env:COMPUTERNAME)-$Label" } else { $env:COMPUTERNAME }
$jsonPath = Join-Path $OutDir "$baseName.json"
$report | ConvertTo-Json -Depth 5 | Set-Content $jsonPath -Encoding UTF8

$md = [System.Text.StringBuilder]::new()
[void]$md.AppendLine("# ODBC vs driverless: $baseName")
[void]$md.AppendLine("")
foreach ($k in $envInfo.Keys) { [void]$md.AppendLine("- **$k**: $($envInfo[$k])") }
[void]$md.AppendLine("- **overhead**: $($overhead.MedianMs) ms median (trivial query; subtracted for eval-only)")
[void]$md.AppendLine("")
[void]$md.AppendLine("Median of $Runs runs, wall clock per PQTest.exe process, warm cache.")
[void]$md.AppendLine("")
[void]$md.AppendLine("| pairing | output | driverless wall (ms) | odbc wall (ms) | driverless eval (ms) | odbc eval (ms) | eval ratio |")
[void]$md.AppendLine("|---|---:|---:|---:|---:|---:|---:|")
foreach ($r in $pairingResults) {
    if ($r.status -eq "skipped") {
        [void]$md.AppendLine("| $($r.name) | skipped: $($r.reason) | | | | | |")
    } else {
        [void]$md.AppendLine("| $($r.name) | $($r.output) | $($r.driverless.medianMs) | $($r.odbc.medianMs) | $($r.driverless.evalMs) | $($r.odbc.evalMs) | $($r.evalRatio)x |")
    }
}
$mdPath = Join-Path $OutDir "$baseName.md"
$md.ToString() | Set-Content $mdPath -Encoding UTF8

Write-Host ""
Write-Host "Wrote $jsonPath"
Write-Host "Wrote $mdPath"
