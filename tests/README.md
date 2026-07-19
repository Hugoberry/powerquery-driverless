# PQTest suite

Runs every reader against its committed fixtures on a real Power Query engine
(PQTest.exe from the [Microsoft.PowerQuery.SdkTools](https://www.nuget.org/packages/Microsoft.PowerQuery.SdkTools)
NuGet package), with per-test timings, in CI (`.github/workflows/pq-tests.yml`,
on pull requests and manual dispatch) or locally on any Windows machine.

## How it fits together

1. `build-mez.ps1` assembles **PQDriverless.mez**: a generated section document
   that exposes every reader `.pq` as a shared member (`Sqlite3.Database`,
   `Dbf.Table`, ...), plus every fixture from each reader's `test/` folder
   embedded as a resource named `<reader>.<file>`. `Extension.Contents` only
   exists inside the module, so the section also defines an anonymous data
   source function `PQDriverless.Fixture(optional name)` that serves the
   embedded fixtures to test queries (`PQDriverless.Fixture("dbf.vfp.dbf")`);
   the parameter is optional so the data source path stays constant and one
   anonymous credential covers everything. Because gpkg/mbtiles call
   `Sqlite3.Database` as a sibling query, the section document satisfies that
   reference naturally.
2. `queries/<reader>/<name>.query.pq` are the tests. Each is a single M
   expression. Navigation-table readers are dumped via `Table.ToRecords` per
   entry (full-content check) or `Table.RowCount` (stress fixtures); direct
   readers return their table as-is.
3. `run-tests.ps1` runs each query through `PQTest.exe compare -e <mez> -q <query>`,
   times it, and writes `out/report.md` + `out/report.json` (also appended to
   the GitHub job summary). Expected outputs live next to each query as
   `<name>.query.pqout`.
4. `perf/` holds the benchmark: `make_perf_fixtures.py` generates large
   fixtures at CI time (row counts are workflow inputs), and `perf/queries/*`
   are row-count queries that are timed but never compared, so the benchmark
   sizes can change without touching baselines.

## Recording baselines

`.pqout` files are recorded by the first run on Windows (PQTest writes the
output when none exists; the report marks those tests RECORDED). Review them
against each reader's `test/expected.md`, then commit them. After that any
drift fails the run.

## Running locally (Windows)

```powershell
nuget install Microsoft.PowerQuery.SdkTools -OutputDirectory .pqtools -NonInteractive
python tests/perf/make_perf_fixtures.py        # optional, perf only
pwsh tests/build-mez.ps1
pwsh tests/run-tests.ps1
```

## Findings from the first CI runs

1. `PQTest.exe compare` exits 0 even when the query fails; `run-tests.ps1`
   parses the `Status` field of the JSON output instead.
2. Test queries cannot call `Extension.Contents` (module scope only) - hence
   the `PQDriverless.Fixture` data source function, plus a
   `set-credential -ak anonymous` step against `credential.query.pq` before
   the suite runs, and a `PQTest info -e` sanity check that the module loads.
3. `compare` auto-records `<name>.query.pqout` next to the query when it is
   missing, as documented. Once baselines are committed, a strict mode via
   `--failOnMissingOutputFile` can prevent silent re-recording.

## Ideas for later iterations

- Compare `report.json` against the base branch's run and post the delta as a
  PR comment (that turns the perf report into a regression gate).
- Move to the DataConnectors `RunPQSDKTestSuites.ps1` layout once the suite
  grows past smoke tests, and pin the SdkTools version.
- Publish PQDriverless.mez as a release artifact; it is already a usable
  "every reader in one connector" build.
- Grow per-reader coverage from one or two smoke queries to the full fixture
  matrix (mechanical: add a `.query.pq`, run once, commit the `.pqout`).
