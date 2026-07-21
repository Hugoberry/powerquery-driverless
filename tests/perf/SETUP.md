# Benchmark environment setup

How to replicate the ODBC-vs-driverless benchmark environment
(`run-odbc-benchmark.ps1`, results in `tests/perf/results/`, analysis in
`tests/perf/REPORT.md`) on a fresh Windows 11 machine, including the
script-engine route (Python/R) used for the formats that have no ODBC
driver.

## 1. Core toolchain (needed for everything)

- **PowerShell 7** (`winget install Microsoft.PowerShell`). Use `pwsh`, not
  Windows PowerShell 5.1 — the test scripts redirect native stderr under
  `$ErrorActionPreference = "Stop"`, which 5.1 turns into spurious failures.
- **Python 3.x** on PATH (fixture generation is stdlib-only).
- **Power Query SDK tools** into the repo's gitignored `.pqtools/`:

  ```powershell
  nuget install Microsoft.PowerQuery.SdkTools -OutputDirectory .pqtools
  ```

Build/run loop (fixtures must exist before the mez build — they are
embedded in it):

```powershell
python tests/perf/make_perf_fixtures.py            # synthetic bulk fixtures
pwsh tests/perf/make_ace_fixtures.ps1              # ACE-real fixtures; needs Office (below)
pwsh tests/build-mez.ps1
pwsh tests/perf/run-odbc-benchmark.ps1             # 1x scale
pwsh tests/perf/run-odbc-benchmark.ps1 -Label 10x  # after regenerating fixtures at 10x
```

Results land in `tests/perf/results/<hostname>[-<label>].json+md` with the
hardware/software environment captured per run.

## 2. ODBC pairings

- **sqlite3** — sqliteodbc 64-bit (Christian Werner,
  http://www.ch-werner.de/sqliteodbc/). Not in winget; run the
  `sqliteodbc_w64.exe` installer manually. Registers as
  `SQLite3 ODBC Driver` in HKLM.
- **xlsb / xls / access / dbf** — 64-bit **Microsoft Office** provides the
  ACE ODBC drivers, and `make_ace_fixtures.ps1` needs Excel COM automation
  and DAO from the same install. Do **not** install the standalone Access
  Database Engine redistributable on a machine that will get Office later —
  the side-by-side install conflicts are notorious.

Pairings whose driver or fixture is missing are recorded as `skipped`, so a
machine without Office still produces a valid (sqlite3-only) results file.

## 3. Script-engine route (Python / R inside the Power Query engine)

The remaining formats (avro, evtx, stata, spss, matlab, gpkg, mbtiles) have
no mainstream ODBC driver; their native counterparts are Python/R libraries
driven through the engine's script providers. `Python.Execute` / `R.Execute`
are not shipped with the SDK tools, but they are thin wrappers over an
ADO.NET provider that Power BI Desktop installs — and that provider can be
registered for PQTest.

### 3.1 Interpreters and libraries

```powershell
python -m pip install pandas matplotlib fastavro pyreadstat scipy evtx geopandas pyogrio
winget install RProject.R
# haven into a personal library (the system library is not writable unelevated):
$lib = "$env:USERPROFILE\R\win-library\4.6"
New-Item $lib -ItemType Directory -Force | Out-Null
& "C:\Program Files\R\R-4.6.1\bin\Rscript.exe" -e "install.packages('haven', lib='$($lib -replace '\\','/')', repos='https://cloud.r-project.org')"
```

R scripts that use haven must see `R_LIBS_USER` pointing at that library
(set it in the shell that launches PQTest).

### 3.2 Power BI Desktop and provider registration

```powershell
winget install Microsoft.PowerBIDesktop
```

Both script providers live in a single assembly of that install,
`bin\Microsoft.PowerBI.Scripting.dll`, registered only for PBIDesktop.exe.
To make them available to PQTest (all inside gitignored `.pqtools/` —
**redo this after any SDK tools reinstall**):

```powershell
$tools = Get-ChildItem .pqtools -Directory -Filter "Microsoft.PowerQuery.SdkTools*" |
         Select-Object -First 1 | ForEach-Object { Join-Path $_.FullName "tools" }
$dll = "C:\Program Files\Microsoft Power BI Desktop\bin\Microsoft.PowerBI.Scripting.dll"
Copy-Item $dll $tools                     # next to PQTest.exe
Copy-Item $dll (Join-Path $tools Mashup)  # next to the evaluation container exe

$section = @"
  <system.data>
    <DbProviderFactories>
      <add name="R" invariant="R.Provider" description="R script provider (PBI Desktop)" type="Microsoft.PowerBI.Scripting.R.RProviderFactory, Microsoft.PowerBI.Scripting" />
      <add name="Python" invariant="Python.Provider" description="Python script provider (PBI Desktop)" type="Microsoft.PowerBI.Scripting.Python.DbProviders.PythonProviderFactory, Microsoft.PowerBI.Scripting" />
    </DbProviderFactories>
  </system.data>
"@
foreach ($cfg in @("$tools\PQTest.exe.config",
                   "$tools\Mashup\Microsoft.Mashup.Container.NETFX45.exe.config")) {
    $c = Get-Content $cfg -Raw
    if ($c -notmatch "Python.Provider") {
        Set-Content $cfg ($c -replace '</configuration>', "$section</configuration>") -Encoding UTF8
    }
}
```

Notes learned the hard way:

- A provider subfolder + `.config` under `Mashup\ADO.NET Providers\` (the
  pattern the shipped ODAC provider uses) is **not** picked up on its own —
  the `DbProviderFactories` entries must be in both exe configs as above.
- Script queries authenticate with an **integrated Windows** credential.
  The `credential-template -ak windows` output contains `$$USERNAME$$`
  placeholders that get stored literally and then fail as "credentials
  invalid" — pipe this JSON to `set-credential` instead:

  ```json
  {"AuthenticationKind":"Windows","AuthenticationProperties":{},"PrivacySetting":"None","Permissions":[]}
  ```

- Both interpreters are discovered by the provider itself (Python via PATH
  /registry, R via its registry keys) — no extra configuration.

### 3.3 Verifying the registration

Run this query through `PQTest.exe compare -e <mez> -q <file> -p` after
setting the credential above; it should return a `(Name, Value)` table with
a CSV binary:

```
let
    src = AdoDotNet.DataSource("Python.Provider", "Key=Value"),
    response = Value.NativeQuery(src, "import pandas as pd#(lf)result = pd.DataFrame({'a': [1, 2, 3]})", null)
in
    response
```

R equivalent: `AdoDotNet.DataSource("R.Provider", "Key=Value")` with
`RData.FromBinary(response{0}[Result])` to decode.

## 4. Measurement discipline

- **Discard the first pass** on any fresh machine state — post-install
  background work (indexing, AV) can distort timings by orders of
  magnitude. Measure only after times stabilize run-to-run.
- **Absolute times are only comparable within one session.** Machines
  drift (30%+ observed within a single day post-setup). Ratios are the
  portable number; any scaling claim needs both scales measured
  back-to-back in one session.
- Every run captures its environment (CPU, RAM, disk, OS build, power
  plan, driver and Office versions) into the results file — commit those
  files so runs from different machines can sit side by side.
