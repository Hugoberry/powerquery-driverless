# PQTest suite

Runs every reader against its committed fixtures on a real Power Query engine
(PQTest.exe from the [Microsoft.PowerQuery.SdkTools](https://www.nuget.org/packages/Microsoft.PowerQuery.SdkTools)
NuGet package), with per-test timings, in CI (`.github/workflows/pq-tests.yml`,
on pull requests and manual dispatch) or locally on any Windows machine.

## How it fits together

1. `build-mez.ps1` assembles a generated section document that exposes every
   reader `.pq` as a shared member (`Sqlite3.Database`, `Dbf.Table`, ...) and
   packages it into two `.mez` files. Because gpkg/mbtiles call
   `Sqlite3.Database` as a sibling query, the section document satisfies that
   reference naturally.

   **PQDriverless.mez** is the distributable connector to load in Power BI. It
   contains the readers and nothing else: no data source kind, no credential
   label, no fixture accessor. It publishes plain functions that take a binary,
   so it needs no credentials of its own and adds no Get Data entry. The build
   asserts this rather than assuming it - a refactor that leaks test-only
   surface back into the distributable fails the build.

   **PQDriverless.tests.mez** carries the same readers plus every fixture from
   each reader's `test/` folder embedded as a resource named `<reader>.<file>`,
   and is what the test and perf harnesses run against. `Extension.Contents`
   only exists inside the module, so this build *also* defines an anonymous
   data source function `PQDriverless.Fixture(optional name)` that serves the
   embedded fixtures to test queries (`PQDriverless.Fixture("dbf.vfp.dbf")`);
   the parameter is optional so the data source path stays constant and one
   anonymous credential covers everything. That accessor is the reason the two
   section documents differ, and the reason the distributable is built
   separately: shipped, it would be a user-visible function that always fails.

   `-Version <x.y.z>` stamps the section document's `[Version]` attribute. It
   defaults to `0.0.0`; the release workflow passes the git tag, so only a
   tagged build claims a real version.
2. `queries/<reader>/<name>.query.pq` are the tests. Each is a single M
   expression. Navigation-table readers are dumped via `Table.ToRecords` per
   entry (full-content check) or `Table.RowCount` (stress fixtures); direct
   readers return their table as-is.
3. `run-tests.ps1` load-checks **both** packages with `PQTest.exe info` before
   anything else - the distributable has no queries run against it, so this is
   the only thing that proves the shipped build compiles and loads - then runs
   each query through `PQTest.exe compare -e <mez> -q <query>`, times it, and
   writes `out/report.md` + `out/report.json` (also appended to the GitHub job
   summary). Expected outputs live next to each query as `<name>.query.pqout`.
4. `perf/` holds the benchmark: `make_perf_fixtures.py` generates one large
   fixture per random-access reader (stdlib-only; row counts are CLI args,
   the sqlite/dbf ones are workflow inputs), and `perf/queries/*` are
   full-decode queries — they fold every cell of every table into a non-null
   count, so lazy row streaming cannot skip the per-cell decode paths — that
   are timed but never compared, so benchmark sizes can change without
   touching baselines. Access has no synthetic writer and is not covered.

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
4. Error values cannot round-trip through a `.pqout`: they serialize as
   comments, so the reloaded expected value never equals the live error and
   the comparison fails forever after recording. Queries over fixtures with
   deliberate error cells (xlsb `types.xlsb`) must scrub errors to a text
   marker first - see `queries/xlsb/types.query.pq` for the pattern.

## Ideas for later iterations

- Compare `report.json` against the base branch's run and post the delta as a
  PR comment (that turns the perf report into a regression gate).
- Move to the DataConnectors `RunPQSDKTestSuites.ps1` layout once the suite
  grows past smoke tests, and pin the SdkTools version.
- ~~Publish PQDriverless.mez as a release artifact~~ - done: a `vX.Y.Z` tag runs
  the suite and publishes the tested mez to a GitHub release.
- Grow per-reader coverage from one or two smoke queries to the full fixture
  matrix (mechanical: add a `.query.pq`, run once, commit the `.pqout`).
