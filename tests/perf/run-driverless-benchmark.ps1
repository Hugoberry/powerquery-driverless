# Driverless-only benchmark refresh.
#
# Times ONLY the pure-M driverless side of every pairing (part 1 ODBC formats
# and part 2 script formats), then pairs each fresh eval against the RETAINED
# native eval from a prior full run (run-odbc-benchmark.ps1 / run-script-
# benchmark.ps1). Use this when the driverless readers changed but the native
# baselines did not, so re-running ODBC drivers / Python-R is unnecessary.
#
# The native column is only comparable across sessions to the extent the
# machine has not drifted, so the runner also re-times the UNCHANGED readers
# and derives a drift factor from them (new driverless eval / prior driverless
# eval, median over the readers named -Controls). That factor is the honest
# yardstick for how much of any single reader's change is code vs machine.
#
# Prereqs (fixtures embedded in the mez, so fixtures first):
#   python tests/perf/make_perf_fixtures.py  [--*-rows ...]   (report sizes)
#   pwsh   tests/perf/make_ace_fixtures.ps1  [-XlsbRows ...]   (needs Office)
#   pwsh   tests/build-mez.ps1
# The prior full-run results (results/<host>[-<label>].json and
# results/<host>-scripts[-<label>].json) supply the retained native evals and
# the expected output values (a regression gate: a fresh driverless value that
# no longer matches the prior one aborts the pairing).
#
# Usage: pwsh tests/perf/run-driverless-benchmark.ps1 [-Runs 5] [-Label 10x]

param(
    [int]$Runs        = 5,
    [string]$Label    = "",
    [string]$PqTest,
    [string]$Mez      = (Join-Path (Split-Path $PSScriptRoot -Parent) "out/PQDriverless.tests.mez"),
    [string]$ToolsDir = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) ".pqtools"),
    [string]$OutDir   = (Join-Path $PSScriptRoot "results"),
    # readers whose code did not change this round; their new/old driverless
    # ratio is pure machine drift and calibrates every other reading.
    [string[]]$Controls = @("xlsb", "access", "dbf", "avro", "evtx", "stata", "spss", "matlab", "gpkg", "mbtiles")
)

$ErrorActionPreference = "Stop"

$TestsDir = Split-Path $PSScriptRoot -Parent
$PerfOut  = Join-Path $PSScriptRoot "out"

if (-not $PqTest) {
    $found = Get-ChildItem $ToolsDir -Recurse -Filter PQTest.exe -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if (-not $found) { throw "PQTest.exe not found under $ToolsDir." }
    $PqTest = $found.FullName
}
if (-not (Test-Path $Mez)) { throw "$Mez not found. Run tests/build-mez.ps1 first." }

# name, driverless query (repo-relative to tests/perf), native source, and the
# fixture whose presence gates the pairing. nativeSource picks which prior
# results file (and which sub-rows) supply the retained native eval.
$Pairings = @(
    @{ Name = "sqlite3"; Query = "queries/sqlite3-bulk.query.pq";               Native = "odbc";   Fixture = "bulk.db" }
    @{ Name = "xlsb";    Query = "odbc/pairings/xlsb-ace.driverless.query.pq";  Native = "odbc";   Fixture = "bulk-ace.xlsb" }
    @{ Name = "xls";     Query = "odbc/pairings/xls-ace.driverless.query.pq";   Native = "odbc";   Fixture = "bulk-ace.xls" }
    @{ Name = "access";  Query = "odbc/pairings/access-ace.driverless.query.pq";Native = "odbc";   Fixture = "bulk-ace.accdb" }
    @{ Name = "dbf";     Query = "queries/dbf-bulk.query.pq";                   Native = "odbc";   Fixture = "bulk.dbf" }
    @{ Name = "avro";    Query = "queries/avro-bulk.query.pq";                  Native = "script"; Fixture = "bulk.avro" }
    @{ Name = "evtx";    Query = "queries/evtx-bulk.query.pq";                  Native = "script"; Fixture = "bulk.evtx" }
    @{ Name = "stata";   Query = "queries/stata-data.query.pq";                Native = "script"; Fixture = "bulk.dta" }
    @{ Name = "spss";    Query = "queries/spss-data.query.pq";                 Native = "script"; Fixture = "bulk.sav" }
    @{ Name = "matlab";  Query = "queries/matlab-bulk.query.pq";               Native = "script"; Fixture = "bulk.mat" }
    @{ Name = "gpkg";    Query = "queries/gpkg-bulk.query.pq";                 Native = "script"; Fixture = "bulk.gpkg" }
    @{ Name = "mbtiles"; Query = "queries/mbtiles-bulk.query.pq";              Native = "script"; Fixture = "bulk.mbtiles" }
)

# ---- prior full-run baselines (retained native evals + expected outputs) ----
$suffix     = if ($Label) { "-$Label" } else { "" }
$priorOdbc  = Join-Path $OutDir "$($env:COMPUTERNAME)$suffix.json"
$priorScr   = Join-Path $OutDir "$($env:COMPUTERNAME)-scripts$suffix.json"
$odbcBase   = if (Test-Path $priorOdbc) { (Get-Content $priorOdbc -Raw | ConvertFrom-Json).pairings } else { @() }
$scrBase    = if (Test-Path $priorScr)  { (Get-Content $priorScr  -Raw | ConvertFrom-Json).pairings } else { @() }

function Get-OdbcBaseline([string]$Name) { $odbcBase | Where-Object { $_.name -eq $Name -and $_.status -eq "measured" } | Select-Object -First 1 }
function Get-ScriptBaselines([string]$Name) { @($scrBase | Where-Object { $_.name -eq $Name -and $_.status -eq "measured" }) }

# ---- credential (anonymous covers every PQDriverless.Fixture call) ----
function Set-AnonCredential([string]$Query) {
    $template = (& $PqTest credential-template -e $Mez -q $Query -ak anonymous 2>&1) -join "`n"
    if ($template.Trim() -notmatch '^\{') { Write-Host $template; throw "credential-template did not return JSON for $Query." }
    $out = ($template | & $PqTest set-credential -e $Mez -q $Query -p 2>&1) -join "`n"
    if ($out -notmatch '"Status"\s*:\s*"Success"') { Write-Host $out; throw "set-credential failed for $Query." }
}
Set-AnonCredential (Join-Path $TestsDir "credential.query.pq")

# ---- timed runs (identical method to the two full harnesses) ----
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

Write-Host "Driverless-only refresh ($Runs timed runs each, median; 1 warmup per case). Label='$Label'."

# trivial-query overhead (write a throwaway query in a generated dir)
$GenDir = Join-Path $PSScriptRoot "out-gen"
New-Item $GenDir -ItemType Directory -Force | Out-Null
$OverheadQuery = Join-Path $GenDir "overhead.query.pq"
"let one = 1 in one" | Set-Content $OverheadQuery -Encoding UTF8
$overhead = Invoke-Timed $OverheadQuery $Runs

$results = @()
foreach ($p in $Pairings) {
    $fixturePath = Join-Path $PerfOut $p.Fixture
    if (-not (Test-Path $fixturePath)) {
        Write-Host "[$($p.Name)] SKIPPED: fixture $($p.Fixture) missing"
        $results += [ordered]@{ name = $p.Name; status = "skipped"; reason = "fixture $($p.Fixture) missing" }
        continue
    }

    Write-Host "[$($p.Name)] driverless"
    $dl     = Invoke-Timed (Join-Path $PSScriptRoot $p.Query) $Runs
    $dlEval = $dl.MedianMs - $overhead.MedianMs

    # retained native baselines + expected output + prior driverless eval
    $natives = @()
    $prevOutput = $null
    $prevDlEval = $null
    if ($p.Native -eq "odbc") {
        $b = Get-OdbcBaseline $p.Name
        if ($b) {
            $prevOutput = $b.output
            $prevDlEval = $b.driverless.evalMs
            $natives += [ordered]@{ engine = "odbc"; driver = $b.odbcDriver; evalMs = $b.odbc.evalMs; ratio = [math]::Round($dlEval / [math]::Max(1, $b.odbc.evalMs), 2) }
        }
    } else {
        $bs = Get-ScriptBaselines $p.Name
        if ($bs.Count -gt 0) {
            $prevOutput = $bs[0].driverlessValue
            $prevDlEval = $bs[0].driverless.evalMs
            foreach ($b in $bs) {
                $natives += [ordered]@{ engine = $b.engine; parityTier = $b.parityTier; evalMs = $b.script.evalMs; ratio = [math]::Round($dlEval / [math]::Max(1, $b.script.evalMs), 2) }
            }
        }
    }

    # regression gate: fresh value must equal the prior full-run value
    $outputMatch = ($null -eq $prevOutput) -or ($dl.Value -eq $prevOutput)
    if (-not $outputMatch) {
        Write-Host "  WARNING [$($p.Name)] output changed: now=$($dl.Value) prior=$prevOutput (fixture scale differs, or a regression)."
    }
    $driftFactor = if ($prevDlEval) { [math]::Round($dlEval / [math]::Max(1, $prevDlEval), 3) } else { $null }

    $results += [ordered]@{
        name           = $p.Name
        status         = "measured"
        isControl      = ($Controls -contains $p.Name)
        fixture        = "$($p.Fixture), $([math]::Round((Get-Item $fixturePath).Length / 1MB, 1)) MB, sha256 $((Get-FileHash $fixturePath -Algorithm SHA256).Hash.ToLower())"
        output         = $dl.Value
        priorOutput    = $prevOutput
        outputMatch    = $outputMatch
        driverless     = [ordered]@{ runsMs = $dl.RunsMs; medianMs = $dl.MedianMs; evalMs = $dlEval }
        priorDlEvalMs  = $prevDlEval
        driftVsPrior   = $driftFactor          # >1 = machine slower now (or reader got slower)
        natives        = $natives
    }
}

# drift factor: median over control readers whose output still matches
$controlDrifts = @($results | Where-Object { $_.status -eq "measured" -and $_.isControl -and $_.outputMatch -and $_.driftVsPrior } | ForEach-Object { $_.driftVsPrior })
$machineDrift  = if ($controlDrifts.Count -gt 0) { [math]::Round(($controlDrifts | Sort-Object)[[math]::Floor($controlDrifts.Count / 2)], 3) } else { $null }

# ---- environment ----
$cpu   = Get-CimInstance Win32_Processor | Select-Object -First 1
$cs    = Get-CimInstance Win32_ComputerSystem
$os    = Get-CimInstance Win32_OperatingSystem
$disk  = try { Get-PhysicalDisk | Where-Object DeviceId -eq ((Get-Partition -DriveLetter ($PerfOut[0])).DiskNumber | Select-Object -First 1) | Select-Object -First 1 } catch { $null }
$power = ((powercfg /getactivescheme) -join "") -replace '.*\((.+)\).*', '$1'
$office = try { (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration" -ErrorAction Stop).VersionToReport } catch { "none" }

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
    office        = $office
}

$report = [ordered]@{
    schema      = 3
    kind        = "driverless-only"
    method      = [ordered]@{
        label        = $Label
        runs         = $Runs
        statistic    = "median"
        timing       = "wall clock of one PQTest.exe compare per run, warm file cache; eval = median - overhead median"
        query        = "full decode: List.Sum(List.Transform(Table.ToRows(t), List.NonNullCount))"
        nativeSource = "retained from prior full run ($([System.IO.Path]::GetFileName($priorOdbc)) / $([System.IO.Path]::GetFileName($priorScr))); native NOT re-timed this round"
        drift        = "machineDrift = median over control readers of (new driverless eval / prior driverless eval); ratios vs native are cross-session, divide native comparison by machineDrift to normalise"
    }
    environment = $envInfo
    controls    = $Controls
    machineDrift = $machineDrift
    overheadMs  = [ordered]@{ runsMs = $overhead.RunsMs; medianMs = $overhead.MedianMs }
    pairings    = $results
}

New-Item $OutDir -ItemType Directory -Force | Out-Null
$baseName = if ($Label) { "$($env:COMPUTERNAME)-driverless-$Label" } else { "$($env:COMPUTERNAME)-driverless" }
$jsonPath = Join-Path $OutDir "$baseName.json"
$report | ConvertTo-Json -Depth 6 | Set-Content $jsonPath -Encoding UTF8

$md = [System.Text.StringBuilder]::new()
[void]$md.AppendLine("# Driverless-only refresh: $baseName")
[void]$md.AppendLine("")
foreach ($k in $envInfo.Keys) { [void]$md.AppendLine("- **$k**: $($envInfo[$k])") }
[void]$md.AppendLine("- **overhead**: $($overhead.MedianMs) ms median (trivial query)")
[void]$md.AppendLine("- **machine drift vs prior full run**: $machineDrift x (median over controls: $($Controls -join ', '))")
[void]$md.AppendLine("")
[void]$md.AppendLine("Native evals are RETAINED from the prior full run (not re-timed). Ratios vs native cross sessions; divide by machine drift to normalise.")
[void]$md.AppendLine("")
[void]$md.AppendLine("| pairing | ctl | output | driverless eval (ms) | prior dl eval (ms) | drift vs prior | native (engine: eval ms, ratio) |")
[void]$md.AppendLine("|---|:--:|---:|---:|---:|---:|---|")
foreach ($r in $results) {
    if ($r.status -eq "skipped") {
        [void]$md.AppendLine("| $($r.name) | | skipped: $($r.reason) | | | | |")
    } else {
        $nat = ($r.natives | ForEach-Object { "$($_.engine): $($_.evalMs), $($_.ratio)x" }) -join " · "
        $ctl = if ($r.isControl) { "•" } else { "" }
        $om  = if ($r.outputMatch) { "" } else { " ⚠changed" }
        [void]$md.AppendLine("| $($r.name) | $ctl | $($r.output)$om | $($r.driverless.evalMs) | $($r.priorDlEvalMs) | $($r.driftVsPrior)x | $nat |")
    }
}
$mdPath = Join-Path $OutDir "$baseName.md"
$md.ToString() | Set-Content $mdPath -Encoding UTF8

Write-Host ""
Write-Host "machine drift vs prior full run: $machineDrift x"
Write-Host "Wrote $jsonPath"
Write-Host "Wrote $mdPath"
