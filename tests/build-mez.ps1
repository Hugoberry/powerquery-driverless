# Assembles the PQDriverless section document into two .mez packages:
#
#   PQDriverless.mez        slim - the section document only. This is the
#                           distributable connector (load it in Power BI).
#   PQDriverless.tests.mez  section document + every test fixture embedded as a
#                           resource, so test queries can load them with
#                           Extension.Contents and stay path-free. Consumed by
#                           run-tests.ps1 and the perf harnesses; not shipped.
#
# The reader code is identical in both. The tests package additionally carries
# the fixtures and the test-only PQDriverless.Fixture accessor that serves them;
# neither is present in the distributable, which exports readers and nothing
# else.
#
# A .mez is a zip. Layout of the tests package:
#   PQDriverless.pq          section document (generated below)
#   <reader>.<fixture>       e.g. sqlite3.types.db, dbf.vfp.fpt
#   perf.<fixture>           CI-generated large fixtures, if present
# The slim package contains PQDriverless.pq alone.
#
# Usage: pwsh tests/build-mez.ps1 [-RepoRoot <path>] [-OutDir <path>] [-Version <x.y.z>]

param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$OutDir   = (Join-Path $PSScriptRoot "out"),
    # Stamped into the section document's [Version] attribute. The release
    # workflow passes the git tag; everything else gets the placeholder.
    [string]$Version  = "0.0.0"
)

$ErrorActionPreference = "Stop"

# folder => .pq files exposed as section members (member name = file name sans .pq)
#
# A file name that collides with a built-in engine function aborts the whole
# module compile, so readers are named to avoid one - AccessReader.Database
# rather than Access.Database. Keep new readers clear of the built-in namespace.
$Readers = @(
    "sqlite3", "gpkg", "mbtiles", "access", "avro", "dbf",
    "evtx", "matlab", "spss", "stata", "xls", "xlsb",
    "crc32", "codec-oracle"
)

New-Item $OutDir -ItemType Directory -Force | Out-Null

# ---- section document ----
# Built twice. The distributable exports the readers and nothing else: no data
# source kind, no credential label, no fixture accessor. Anything test-only that
# ships in it is user-visible surface that always fails when called, and the
# credential label is what a user would be shown if the engine ever prompted.
#
# The tests build adds the Fixture accessor, which is the module's (anonymous)
# data source function: test queries cannot call Extension.Contents themselves,
# so fixtures are served through it. Its parameter is optional on purpose -
# optional parameters stay out of the data source path, so one anonymous
# credential covers every call.
function New-SectionDoc {
    param([switch]$WithFixtures)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("[Version = ""$Version""]")
    [void]$sb.AppendLine('section PQDriverless;')
    [void]$sb.AppendLine('')

    if ($WithFixtures) {
        [void]$sb.AppendLine('PQDriverless = [ Authentication = [ Anonymous = [] ], Label = "PQDriverless test module" ];')
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('[DataSource.Kind = "PQDriverless"]')
        [void]$sb.AppendLine('shared PQDriverless.Fixture = (optional name as text) as binary => Extension.Contents(name);')
        [void]$sb.AppendLine('')
    }

    foreach ($dir in $Readers) {
        $full = Join-Path $RepoRoot $dir
        if (-not (Test-Path $full)) { continue }
        foreach ($pq in Get-ChildItem $full -Filter *.pq -File) {
            $name = $pq.BaseName
            $body = Get-Content $pq.FullName -Raw
            [void]$sb.AppendLine("// ==== $dir/$($pq.Name) ====")
            [void]$sb.AppendLine("shared $name =")
            [void]$sb.AppendLine($body.TrimEnd())
            [void]$sb.AppendLine(";")
            [void]$sb.AppendLine("")
        }
    }
    $sb.ToString()
}

$SlimDoc  = New-SectionDoc
$TestsDoc = New-SectionDoc -WithFixtures

# The whole point of the split, asserted rather than assumed: a refactor that
# leaks the test harness back into the distributable fails the build here.
foreach ($needle in @("PQDriverless.Fixture", "Extension.Contents", "DataSource.Kind", "test module")) {
    if ($SlimDoc -match [regex]::Escape($needle)) {
        throw "Distributable section document contains test-only surface: '$needle'"
    }
}

# ---- stage both packages ----
$StageRoot = Join-Path $OutDir "stage"
if (Test-Path $StageRoot) { Remove-Item $StageRoot -Recurse -Force }
$SlimStage = Join-Path $StageRoot "slim"
$FullStage = Join-Path $StageRoot "full"
New-Item $SlimStage -ItemType Directory -Force | Out-Null
New-Item $FullStage -ItemType Directory -Force | Out-Null

Set-Content (Join-Path $SlimStage "PQDriverless.pq") $SlimDoc  -Encoding UTF8
Set-Content (Join-Path $FullStage "PQDriverless.pq") $TestsDoc -Encoding UTF8

# ---- fixtures (tests package only) ----
$SkipExt = @(".py", ".md", ".java", ".pyc")
foreach ($dir in $Readers) {
    $testDir = Join-Path (Join-Path $RepoRoot $dir) "test"
    if (-not (Test-Path $testDir)) { continue }
    foreach ($f in Get-ChildItem $testDir -File) {
        if ($SkipExt -contains $f.Extension.ToLower()) { continue }
        Copy-Item $f.FullName (Join-Path $FullStage "$dir.$($f.Name)")
    }
}

# CI-generated perf fixtures (tests/perf/out), embedded as perf.<name>
$PerfOut = Join-Path $PSScriptRoot "perf/out"
if (Test-Path $PerfOut) {
    foreach ($f in Get-ChildItem $PerfOut -File) {
        Copy-Item $f.FullName (Join-Path $FullStage "perf.$($f.Name)")
    }
}

# ---- package ----
function New-Mez {
    param([string]$StageDir, [string]$MezPath)

    if (Test-Path $MezPath) { Remove-Item $MezPath -Force }
    $ZipPath = "$MezPath.zip"
    if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
    Compress-Archive -Path (Join-Path $StageDir "*") -DestinationPath $ZipPath
    Move-Item $ZipPath $MezPath

    $count = (Get-ChildItem $StageDir -File).Count
    Write-Host ("Built {0} v{1} ({2} files, {3} MB)" -f `
        $MezPath, $Version, $count, [math]::Round((Get-Item $MezPath).Length / 1MB, 1))
}

New-Mez $SlimStage (Join-Path $OutDir "PQDriverless.mez")
New-Mez $FullStage (Join-Path $OutDir "PQDriverless.tests.mez")
