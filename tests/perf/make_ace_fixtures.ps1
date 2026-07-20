# Generates ACE-readable bulk fixtures for the ODBC-vs-driverless benchmark.
# The synthetic xls/xlsb from make_perf_fixtures.py are minimal enough that the
# ACE Excel ODBC driver rejects them ("External table is not in the expected
# format"), and Access has no synthetic writer at all - so these are authored
# through the real engines: Excel COM automation for the workbooks, DAO for
# the .accdb. Requires Office (64-bit) on the machine; outputs land next to
# the CI fixtures in tests/perf/out and are embedded in the mez by
# build-mez.ps1 as perf.bulk-ace.*.
#
# The workbooks get a header row (id/value/flag/name) because the ACE ODBC
# driver always consumes the first row as column names (FirstRowHasNames is
# not accepted as a connection attribute); the driverless pairing queries
# Table.Skip(1) to fold the same data cells.
#
# Data mirrors the synthetic fixtures: id = row index, value = LCG pseudo-
# random in [0,1000), flag = id mod 2, name = "row-0000000".
#
# Usage: pwsh tests/perf/make_ace_fixtures.ps1 [-XlsbRows 10000] [-XlsRows 8000] [-AccessRows 20000]

param(
    [int]$XlsbRows   = 10000,
    [int]$XlsRows    = 8000,
    [int]$AccessRows = 20000,
    [string]$OutDir  = (Join-Path $PSScriptRoot "out")
)

$ErrorActionPreference = "Stop"
New-Item $OutDir -ItemType Directory -Force | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

# Deterministic LCG so every machine gets identical fixture bytes-in-values.
function New-Lcg { [pscustomobject]@{ s = [uint64]42 } }
function Next-Value($lcg) {
    $lcg.s = ($lcg.s * 6364136223846793005 + 1442695040888963407) % ([uint64]::MaxValue)
    [math]::Round((($lcg.s -shr 16) % 1000000) / 1000.0, 3)   # [0, 1000)
}

# ---- workbooks via Excel COM ----
function Write-Workbook([string]$Path, [int]$Rows, [int]$Cols, [int]$FileFormat) {
    $lcg = New-Lcg
    $data = New-Object 'object[,]' ($Rows + 1), $Cols
    $headers = @("id", "value", "flag", "name")
    for ($c = 0; $c -lt $Cols; $c++) { $data[0, $c] = $headers[$c] }
    for ($r = 1; $r -le $Rows; $r++) {
        $data[$r, 0] = $r - 1
        $data[$r, 1] = Next-Value $lcg
        $data[$r, 2] = ($r - 1) % 2
        if ($Cols -ge 4) { $data[$r, 3] = "row-{0:d7}" -f ($r - 1) }
    }
    $wb = $script:xl.Workbooks.Add()
    $ws = $wb.Worksheets.Item(1)
    $ws.Name = "Bulk"
    $range = $ws.Range($ws.Cells(1, 1), $ws.Cells($Rows + 1, $Cols))
    $range.Value2 = $data
    if (Test-Path $Path) { Remove-Item $Path -Force }
    $wb.SaveAs($Path, $FileFormat)
    $wb.Close($false)
    Write-Host "Wrote $Path ($Rows rows x $Cols cols + header)"
}

$xl = New-Object -ComObject Excel.Application
$xl.Visible = $false
$xl.DisplayAlerts = $false
try {
    Write-Workbook (Join-Path $OutDir "bulk-ace.xlsb") $XlsbRows 4 50   # xlExcel12 (.xlsb)
    Write-Workbook (Join-Path $OutDir "bulk-ace.xls")  $XlsRows  3 56   # xlExcel8 (.xls)
} finally {
    $xl.Quit()
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($xl)
}

# ---- accdb via DAO ----
$accdb = Join-Path $OutDir "bulk-ace.accdb"
if (Test-Path $accdb) { Remove-Item $accdb -Force }
$dao = New-Object -ComObject DAO.DBEngine.120
$db = $dao.CreateDatabase($accdb, ";LANGID=0x0409;CP=1252;COUNTRY=0")
try {
    $db.Execute("CREATE TABLE data ([id] LONG, [name] TEXT(20), [value] DOUBLE, [flag] LONG)")
    $rs = $db.OpenRecordset("data")
    $lcg = New-Lcg
    for ($r = 0; $r -lt $AccessRows; $r++) {
        $v = [double](Next-Value $lcg)
        $rs.AddNew()
        $rs.Fields.Item("id").Value    = [int]$r
        $rs.Fields.Item("name").Value  = "row-{0:d7}" -f $r
        $rs.Fields.Item("value").Value = $v
        $rs.Fields.Item("flag").Value  = [int]($r % 2)
        $rs.Update()
    }
    $rs.Close()
    Write-Host "Wrote $accdb ($AccessRows rows x 4 cols)"
} finally {
    $db.Close()
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($dao)
}
