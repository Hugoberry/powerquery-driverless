# Assembles PQDriverless.mez: one section document exposing every reader as a
# shared member, plus every test fixture embedded as a resource so test queries
# can load them with Extension.Contents and stay path-free.
#
# A .mez is a zip. Layout produced:
#   PQDriverless.pq          section document (generated below)
#   <reader>.<fixture>       e.g. sqlite3.types.db, dbf.vfp.fpt
#   perf.<fixture>           CI-generated large fixtures, if present
#
# Usage: pwsh tests/build-mez.ps1 [-RepoRoot <path>] [-OutDir <path>]

param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [string]$OutDir   = (Join-Path $PSScriptRoot "out")
)

$ErrorActionPreference = "Stop"

# folder => .pq files exposed as section members (member name = file name sans .pq)
$Readers = @(
    "sqlite3", "gpkg", "mbtiles", "access", "avro", "dbf",
    "evtx", "matlab", "spss", "stata", "xls", "xlsb",
    "crc32", "codec-oracle"
)

$Renames = @{ "Access.Database" = "AccessReader.Database" }

$Stage = Join-Path $OutDir "stage"
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item $Stage -ItemType Directory -Force | Out-Null

# ---- section document ----
# The Fixture accessor is the module's (anonymous) data source function: test
# queries cannot call Extension.Contents themselves, so fixtures are served
# through it. Its parameter is optional on purpose - optional parameters stay
# out of the data source path, so one anonymous credential covers every call.
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('[Version = "1.0.0"]')
[void]$sb.AppendLine('section PQDriverless;')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('PQDriverless = [ Authentication = [ Anonymous = [] ], Label = "PQDriverless test module" ];')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('[DataSource.Kind = "PQDriverless"]')
[void]$sb.AppendLine('shared PQDriverless.Fixture = (optional name as text) as binary => Extension.Contents(name);')
[void]$sb.AppendLine('')

foreach ($dir in $Readers) {
    $full = Join-Path $RepoRoot $dir
    if (-not (Test-Path $full)) { continue }
    foreach ($pq in Get-ChildItem $full -Filter *.pq -File) {
        $name = $pq.BaseName
        # Names that collide with built-in engine functions abort the whole
        # module compile, so those readers are exported under a test-only name.
        if ($Renames.ContainsKey($name)) { $name = $Renames[$name] }
        $body = Get-Content $pq.FullName -Raw
        [void]$sb.AppendLine("// ==== $dir/$($pq.Name) ====")
        [void]$sb.AppendLine("shared $name =")
        [void]$sb.AppendLine($body.TrimEnd())
        [void]$sb.AppendLine(";")
        [void]$sb.AppendLine("")
    }
}

Set-Content (Join-Path $Stage "PQDriverless.pq") $sb.ToString() -Encoding UTF8

# ---- fixtures ----
$SkipExt = @(".py", ".md", ".java", ".pyc")
foreach ($dir in $Readers) {
    $testDir = Join-Path (Join-Path $RepoRoot $dir) "test"
    if (-not (Test-Path $testDir)) { continue }
    foreach ($f in Get-ChildItem $testDir -File) {
        if ($SkipExt -contains $f.Extension.ToLower()) { continue }
        Copy-Item $f.FullName (Join-Path $Stage "$dir.$($f.Name)")
    }
}

# CI-generated perf fixtures (tests/perf/out), embedded as perf.<name>
$PerfOut = Join-Path $PSScriptRoot "perf/out"
if (Test-Path $PerfOut) {
    foreach ($f in Get-ChildItem $PerfOut -File) {
        Copy-Item $f.FullName (Join-Path $Stage "perf.$($f.Name)")
    }
}

# ---- package ----
$MezPath = Join-Path $OutDir "PQDriverless.mez"
if (Test-Path $MezPath) { Remove-Item $MezPath -Force }
$ZipPath = "$MezPath.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $ZipPath
Move-Item $ZipPath $MezPath

$count = (Get-ChildItem $Stage -File).Count
Write-Host "Built $MezPath ($count files, $([math]::Round((Get-Item $MezPath).Length / 1MB, 1)) MB)"
