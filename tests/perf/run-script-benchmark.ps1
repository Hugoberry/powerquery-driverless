# Script-library vs driverless connector benchmark.
#
# The sibling of run-odbc-benchmark.ps1 for the seven formats with no
# mainstream ODBC driver (avro, evtx, stata, spss, matlab, gpkg, mbtiles).
# Each format's driverless reader is timed against the best native library,
# driven through the Power Query engine's Python/R script providers (the same
# path Python.Execute / R.Execute use) so both sides run under one PQTest.exe
# harness and read the identical file.
#
# For each pairing the same full-decode workload runs twice: once with the
# repo's pure-M reader (fixture embedded in PQDriverless.mez), once with a
# Python/R script (context/SCRIPT-PERF-SPEC.md, Route A) reading the file from
# disk and printing one integer. Both must agree on a parity value or the
# pairing aborts:
#   - Tier 1 (exact cell parity): avro, stata, spss, matlab, gpkg, mbtiles.
#     The driverless fold and the library's non-null cell/element count match
#     exactly (stata/spss compare the data matrix only; gpkg adds fid back,
#     which pyogrio maps to the index).
#   - Tier 2 (structural parity): evtx. The driverless reader flattens each
#     event into its own column set while pyevtx-rs yields raw XML, so cell
#     counts differ by design; the gate is the event count instead.
#
# Two overheads are isolated, mirroring the ODBC harness's process floor:
#   - a trivial query times PQTest.exe process startup (driverless eval-only =
#     median - this);
#   - a per-pairing imports-only script (same imports, no file read, prints 0)
#     times PQTest startup + interpreter launch + import + marshalling; script
#     eval-only = median - this. Import cost varies wildly (scipy vs geopandas)
#     so it must be per-pairing.
#
# Results land in tests/perf/results/<hostname>-scripts[-<label>].json + .md.
#
# Prereqs (see tests/perf/SETUP.md; fixtures are embedded in the mez, so
# fixtures first):
#   python tests/perf/make_perf_fixtures.py
#   pwsh   tests/build-mez.ps1
# plus the Python/R interpreters, their libraries, and the Power BI Desktop
# script-provider registration in .pqtools (SETUP.md section 3).
#
# Usage: pwsh tests/perf/run-script-benchmark.ps1 [-Runs 5] [-Label 10x]

param(
    [int]$Runs        = 5,
    [string]$Label    = "",
    [string]$PqTest,
    [string]$Mez      = (Join-Path (Split-Path $PSScriptRoot -Parent) "out/PQDriverless.mez"),
    [string]$ToolsDir = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ".pqtools"),
    [string]$OutDir   = (Join-Path $PSScriptRoot "results"),
    # haven lives in the user library; the R provider's Rscript must see it.
    [string]$RLibsUser = (Join-Path $env:USERPROFILE "R\win-library\4.6")
)

$ErrorActionPreference = "Stop"

$TestsDir = Split-Path $PSScriptRoot -Parent
$PerfOut  = Join-Path $PSScriptRoot "out"
$ScriptDir = Join-Path $PSScriptRoot "scripts"
$env:R_LIBS_USER = $RLibsUser   # inherited by the provider-launched Rscript

if (-not $PqTest) {
    $found = Get-ChildItem $ToolsDir -Recurse -Filter PQTest.exe -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if (-not $found) { throw "PQTest.exe not found under $ToolsDir. nuget install Microsoft.PowerQuery.SdkTools -OutputDirectory $ToolsDir" }
    $PqTest = $found.FullName
}
if (-not (Test-Path $Mez)) { throw "$Mez not found. Run tests/build-mez.ps1 first." }

# name, driverless query (repo-relative to tests/perf), fixture, parity tier,
# structural gate query for Tier 2, and the native engine(s) to pair.
$Pairings = @(
    @{ Name = "avro";    Driverless = "queries/avro-bulk.query.pq";    Fixture = "bulk.avro";    Tier = 1; Engines = @("python") }
    @{ Name = "evtx";    Driverless = "queries/evtx-bulk.query.pq";    Fixture = "bulk.evtx";    Tier = 2; Structural = "queries/evtx-count.query.pq"; Engines = @("python") }
    @{ Name = "stata";   Driverless = "queries/stata-data.query.pq";   Fixture = "bulk.dta";     Tier = 1; Engines = @("python", "r") }
    @{ Name = "spss";    Driverless = "queries/spss-data.query.pq";    Fixture = "bulk.sav";     Tier = 1; Engines = @("python", "r") }
    @{ Name = "matlab";  Driverless = "queries/matlab-bulk.query.pq";  Fixture = "bulk.mat";     Tier = 1; Engines = @("python") }
    @{ Name = "gpkg";    Driverless = "queries/gpkg-bulk.query.pq";    Fixture = "bulk.gpkg";    Tier = 1; Engines = @("python") }
    @{ Name = "mbtiles"; Driverless = "queries/mbtiles-bulk.query.pq"; Fixture = "bulk.mbtiles"; Tier = 1; Engines = @("python") }
)

# ---- generated wrapper queries (absolute paths, so never committed) ----
$GenDir = Join-Path $ScriptDir "out"
New-Item $GenDir -ItemType Directory -Force | Out-Null

$OverheadQuery = Join-Path $GenDir "overhead.query.pq"
"let one = 1 in one" | Set-Content $OverheadQuery -Encoding UTF8

# ---- credentials ----
# Driverless side: one anonymous credential covers every PQDriverless.Fixture
# call (the optional parameter keeps it off the data source path). Script side:
# the Python/R ADO.NET providers authenticate with an integrated Windows
# credential (the credential-template windows output stores $$USERNAME$$
# literally and then fails, so the JSON is fed to set-credential directly).
function Set-AnonCredential([string]$Query) {
    $template = (& $PqTest credential-template -e $Mez -q $Query -ak anonymous 2>&1) -join "`n"
    if ($template.Trim() -notmatch '^\{') { Write-Host $template; throw "credential-template did not return JSON for $Query." }
    $out = ($template | & $PqTest set-credential -e $Mez -q $Query -p 2>&1) -join "`n"
    if ($out -notmatch '"Status"\s*:\s*"Success"') { Write-Host $out; throw "set-credential (anonymous) failed for $Query." }
}
function Set-WindowsCredential([string]$Query) {
    $cred = '{"AuthenticationKind":"Windows","AuthenticationProperties":{},"PrivacySetting":"None","Permissions":[]}'
    $out = ($cred | & $PqTest set-credential -e $Mez -q $Query -p 2>&1) -join "`n"
    if ($out -notmatch '"Status"\s*:\s*"Success"') { Write-Host $out; throw "set-credential (Windows) failed for $Query." }
}
Set-AnonCredential (Join-Path $TestsDir "credential.query.pq")

# ---- script -> wrapper query ----
# The script text is inlined into a Value.NativeQuery call against the Python/R
# provider (context/refs/Python.m and R.m). __PERF_OUT__ becomes the fixture
# path (forward slashes so Python/R never see a backslash escape); the script
# assigns a data frame named result with one column v holding the parity
# integer, which comes back as CSV (Python) or RData (R) and is decoded here.
function Escape-Mstring([string]$s) {
    ($s -replace '"', '""') -replace "`r?`n", '#(lf)'
}
function New-ScriptQuery([string]$Engine, [string]$ScriptFile, [string]$FixturePath, [string]$OutFile) {
    $text = (Get-Content $ScriptFile -Raw).Replace("__PERF_OUT__", ($FixturePath -replace '\\', '/'))
    $esc  = Escape-Mstring $text
    if ($Engine -eq "python") {
        $q = @"
let
    src = AdoDotNet.DataSource("Python.Provider", "Key=Value"),
    response = Value.NativeQuery(src, "$esc", null),
    bin = Table.SelectRows(response, each [Name] = "result"){0}[Value],
    tbl = Table.PromoteHeaders(Csv.Document(bin)),
    v = Number.From(tbl{0}[v])
in
    v
"@
    } else {
        $q = @"
let
    src = AdoDotNet.DataSource("R.Provider", "Key=Value"),
    response = Value.NativeQuery(src, "$esc", null),
    rec = RData.FromBinary(response{0}[Result]),
    v = Number.From(Table.FirstValue(rec[result]))
in
    v
"@
    }
    $q | Set-Content $OutFile -Encoding UTF8
    Set-WindowsCredential $OutFile
}

# ---- timed runs (identical to run-odbc-benchmark.ps1) ----
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
function Get-Value([string]$Query) {
    $pqout = $Query -replace '\.query\.pq$', '.query.pqout'
    if (Test-Path $pqout) { Remove-Item $pqout -Force }
    $raw = (& $PqTest compare -e $Mez -q $Query -p 2>&1) -join "`n"
    try { $j = @($raw | ConvertFrom-Json)[0] } catch { Write-Host $raw; throw "PQTest printed no JSON for $Query." }
    if ($j.Status -ne "Passed") { Write-Host $raw; throw "PQTest run failed for $Query ($($j.Status))." }
    if (Test-Path $pqout) { Remove-Item $pqout -Force }
    $j.Output[0].SerializedSource
}

Write-Host "Benchmarking ($Runs timed runs each, median reported; 1 warmup run per case)..."
$overhead = Invoke-Timed $OverheadQuery $Runs

$rows = @()
foreach ($p in $Pairings) {
    $fixturePath = Join-Path $PerfOut $p.Fixture
    if (-not (Test-Path $fixturePath)) {
        Write-Host "[$($p.Name)] SKIPPED: fixture $($p.Fixture) missing"
        foreach ($eng in $p.Engines) {
            $rows += [ordered]@{ name = $p.Name; engine = $eng; status = "skipped"; reason = "fixture $($p.Fixture) missing" }
        }
        continue
    }

    # driverless side: measured once per format, reused across engines.
    Write-Host "[$($p.Name)] driverless"
    $driverless = Invoke-Timed (Join-Path $PSScriptRoot $p.Driverless) $Runs
    $dlEval = $driverless.MedianMs - $overhead.MedianMs

    # Tier 2 parity gate value (structural), read once.
    $gateValue = if ($p.Tier -eq 2) { Get-Value (Join-Path $PSScriptRoot $p.Structural) } else { $driverless.Value }

    foreach ($eng in $p.Engines) {
        $ext        = if ($eng -eq "python") { "py" } else { "R" }
        $scriptFile = Join-Path $ScriptDir "$($p.Name).$eng.$ext"
        $overFile   = Join-Path $ScriptDir "$($p.Name).$eng.overhead.$ext"
        if (-not (Test-Path $scriptFile)) {
            Write-Host "[$($p.Name)/$eng] SKIPPED: script $scriptFile missing"
            $rows += [ordered]@{ name = $p.Name; engine = $eng; status = "skipped"; reason = "script missing" }
            continue
        }
        Write-Host "[$($p.Name)/$eng] script"
        $decodeQ = Join-Path $GenDir "$($p.Name).$eng.query.pq"
        $overQ   = Join-Path $GenDir "$($p.Name).$eng.overhead.query.pq"
        New-ScriptQuery $eng $scriptFile   $fixturePath $decodeQ
        New-ScriptQuery $eng $overFile     $fixturePath $overQ

        $script   = Invoke-Timed $decodeQ $Runs
        $imports  = Invoke-Timed $overQ   $Runs
        $scEval   = [math]::Max(1, $script.MedianMs - $imports.MedianMs)

        # parity gate
        if ($script.Value -ne $gateValue) {
            throw "[$($p.Name)/$eng] parity mismatch: script=$($script.Value) expected=$gateValue (tier $($p.Tier))."
        }

        $rows += [ordered]@{
            name            = $p.Name
            engine          = $eng
            status          = "measured"
            parityTier      = $p.Tier
            fixture         = "$($p.Fixture), $([math]::Round((Get-Item $fixturePath).Length / 1MB, 1)) MB, sha256 $((Get-FileHash $fixturePath -Algorithm SHA256).Hash.ToLower())"
            parityValue     = $gateValue
            driverlessValue = $driverless.Value
            scriptValue     = $script.Value
            driverless      = [ordered]@{ runsMs = $driverless.RunsMs; medianMs = $driverless.MedianMs; evalMs = $dlEval }
            script          = [ordered]@{ runsMs = $script.RunsMs;     medianMs = $script.MedianMs;     evalMs = $scEval }
            importsOverhead = [ordered]@{ runsMs = $imports.RunsMs;    medianMs = $imports.MedianMs }
            wallRatio       = [math]::Round($driverless.MedianMs / $script.MedianMs, 2)
            evalRatio       = [math]::Round($dlEval / $scEval, 2)
        }
    }
}

# ---- environment ----
$cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
$cs    = Get-CimInstance Win32_ComputerSystem
$os    = Get-CimInstance Win32_OperatingSystem
$disk  = try { Get-PhysicalDisk | Where-Object DeviceId -eq ((Get-Partition -DriveLetter ($PerfOut[0])).DiskNumber | Select-Object -First 1) | Select-Object -First 1 } catch { $null }
$power = ((powercfg /getactivescheme) -join "") -replace '.*\((.+)\).*', '$1'

$pyVersion = (& python --version 2>&1) -replace '^Python\s*', ''
$pyLibs = try {
    (& python -c "import importlib.metadata as m; print('; '.join(p+' '+m.version(p) for p in ['pandas','fastavro','pyreadstat','scipy','pyogrio','evtx']))" 2>&1) -join ""
} catch { "unknown" }
$rscript = (Get-Command Rscript.exe -ErrorAction SilentlyContinue).Source
if (-not $rscript) {
    $rscript = Get-ChildItem "C:\Program Files\R" -Recurse -Filter Rscript.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
}
$rVersion = try { (& $rscript -e "cat(as.character(getRversion()))" 2>$null) -join "" } catch { "unknown" }
$havenVersion = try { (& $rscript -e "cat(as.character(packageVersion('haven')))" 2>$null) -join "" } catch { "unknown" }

$envInfo = [ordered]@{
    machine       = $env:COMPUTERNAME
    timestamp     = (Get-Date).ToString("yyyy-MM-ddTHH:mm:sszzz")
    cpu           = $cpu.Name.Trim()
    cores         = $cpu.NumberOfCores
    logicalCpus   = $cpu.NumberOfLogicalProcessors
    ramGB         = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
    disk          = if ($disk) { "$($disk.FriendlyName) ($($disk.MediaType), $($disk.BusType))" } else { "unknown" }
    os            = "$($os.Caption.Trim()) build $($os.BuildNumber)"
    powerPlan     = $power
    pqTestVersion = (Get-Item $PqTest).VersionInfo.FileVersion
    pythonVersion = $pyVersion
    pythonLibs    = $pyLibs
    rVersion      = $rVersion
    havenVersion  = $havenVersion
}

$report = [ordered]@{
    schema      = 2
    method      = [ordered]@{
        label     = $Label
        runs      = $Runs
        statistic = "median"
        timing    = "wall clock of one PQTest.exe compare per run, warm file cache; includes process startup (see overheadMs) and, for scripts, interpreter launch + import + CSV/RData marshalling (see per-pairing importsOverhead)"
        query     = "driverless: full-decode fold; script: same workload in Python/R printing one parity integer (Tier 1 exact cell parity, Tier 2 structural). driverless eval = median - overhead; script eval = median - importsOverhead"
        route     = "A: scripts run inside the PQ engine via the Python/R ADO.NET providers (context/SCRIPT-PERF-SPEC.md)"
    }
    environment = $envInfo
    overheadMs  = [ordered]@{ runsMs = $overhead.RunsMs; medianMs = $overhead.MedianMs }
    pairings    = $rows
}

New-Item $OutDir -ItemType Directory -Force | Out-Null
$baseName = if ($Label) { "$($env:COMPUTERNAME)-scripts-$Label" } else { "$($env:COMPUTERNAME)-scripts" }
$jsonPath = Join-Path $OutDir "$baseName.json"
$report | ConvertTo-Json -Depth 6 | Set-Content $jsonPath -Encoding UTF8

$md = [System.Text.StringBuilder]::new()
[void]$md.AppendLine("# Script-library vs driverless: $baseName")
[void]$md.AppendLine("")
foreach ($k in $envInfo.Keys) { [void]$md.AppendLine("- **$k**: $($envInfo[$k])") }
[void]$md.AppendLine("- **overhead**: $($overhead.MedianMs) ms median (trivial query; PQTest process floor)")
[void]$md.AppendLine("")
[void]$md.AppendLine("Median of $Runs runs, wall clock per PQTest.exe process, warm cache. Script eval subtracts the per-pairing imports-only floor (PQTest + interpreter launch + import + marshalling); driverless eval subtracts the trivial-query floor.")
[void]$md.AppendLine("")
[void]$md.AppendLine("| pairing | engine | tier | parity | driverless eval (ms) | script eval (ms) | imports floor (ms) | eval ratio |")
[void]$md.AppendLine("|---|---|---|---:|---:|---:|---:|---:|")
foreach ($r in $rows) {
    if ($r.status -eq "skipped") {
        [void]$md.AppendLine("| $($r.name) | $($r.engine) | | skipped: $($r.reason) | | | | |")
    } else {
        $parity = if ($r.parityTier -eq 2) { "$($r.parityValue) (struct)" } else { "$($r.parityValue)" }
        [void]$md.AppendLine("| $($r.name) | $($r.engine) | $($r.parityTier) | $parity | $($r.driverless.evalMs) | $($r.script.evalMs) | $($r.importsOverhead.medianMs) | $($r.evalRatio)x |")
    }
}
$mdPath = Join-Path $OutDir "$baseName.md"
$md.ToString() | Set-Content $mdPath -Encoding UTF8

Write-Host ""
Write-Host "Wrote $jsonPath"
Write-Host "Wrote $mdPath"
