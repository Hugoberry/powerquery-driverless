# ODBC driver vs driverless connector

The same full-decode query, the same file, the same harness — once through a
native ODBC driver, once through the pure-M driverless reader. This report
grows as pairings and machines are added; per-machine raw data lives in
`tests/perf/results/<hostname>[-<label>].json+md`.

Updated **21 Jul 2026** · 1 machine · 5 pairings · 2 scales (1x and 10x rows)
· branch `odbc-vs-driverless` (includes the `61cb250` xlsb fix)

## Key numbers

- **Small files (1x): 1.0–2.9x against ACE** (sqlite3 11.1x) — and dbf is a
  dead heat: the pure-M reader matches Office's own dBASE driver.
- **At 10x scale: 2.3–15.2x** — native drivers win everywhere once their
  setup cost amortizes.
- **ODBC setup floor: ~0.7–1 s** per driver connection — dominates small
  files.
- **Driverless scaling is linear** on every reader (9.7–10.1x time for 10x
  rows; xls/access/dbf slightly sublinear). The xlsb superlinearity found in
  the first scaling pass was real and is fixed (`61cb250`).
- **Output parity: 10/10 exact** — every pairing, both scales; the runner
  aborts on any mismatch.

Both scales below were measured back-to-back on 21 Jul with the fixed
reader, so the scaling multiples are drift-free.

## Results — 1x fixtures (WOOM, 21 Jul 2026)

Median of 5 runs, wall clock per PQTest.exe process, warm cache.
Eval = median wall minus trivial-query overhead (2 582 ms this session).

| pairing | fixture | output | driver | driverless wall / eval (ms) | odbc wall / eval (ms) | eval ratio |
|---|---|---:|---|---:|---:|---:|
| sqlite3 | 200k rows x 4 | 800 000 | sqliteodbc 0.99991 | 14 471 / 11 889 | 3 650 / 1 068 | 11.13x |
| xlsb | 10k rows x 4 | 40 000 | ACE Excel 16.0 | 4 843 / 2 261 | 3 359 / 777 | 2.91x |
| xls | 8k rows x 3 | 24 000 | ACE Excel 16.0 | 3 876 / 1 294 | 3 265 / 683 | 1.89x |
| access | 20k rows x 4 | 80 000 | ACE Access 16.0 | 4 028 / 1 446 | 3 350 / 768 | 1.88x |
| dbf | 20k rows x 3 | 60 000 | ACE dBASE 16.0 | 3 491 / 909 | 3 494 / 912 | **1.00x** |

Ratios > 1 favour the native driver. Only sqlite3 shows an order-of-magnitude
gap — sqlite's C library does minimal per-row work, while ACE pays real
bridging cost per row. dbf has ranged 0.78–1.00x across sessions: parity,
with the driverless reader sometimes ahead.

## Scaling — 10x rows (WOOM-10x, 21 Jul 2026)

Fixtures scaled 10x: sqlite3 2M rows, xlsb 100k, access 200k, dbf 200k — and
xls capped at 65k by the BIFF8 format's 65 536-row limit. Same method,
overhead 2 517 ms this session.

| pairing | fixture | output | driverless eval (ms) | odbc eval (ms) | eval ratio | 1x ratio | driverless time scaling |
|---|---|---:|---:|---:|---:|---:|---|
| sqlite3 | 2M rows x 4 | 8 000 000 | 115 086 | 7 564 | 15.21x | 11.13x | 9.7x for 10x rows — linear |
| xlsb | 100k rows x 4 | 400 000 | 22 869 | 2 291 | 9.98x | 2.91x | 10.1x for 10x rows — linear (post-fix) |
| xls | 65k rows x 3 | 195 000 | 8 340 | 1 109 | 7.52x | 1.89x | 6.4x for 8.1x rows — sublinear |
| access | 200k rows x 4 | 800 000 | 10 867 | 1 615 | 6.73x | 1.88x | 7.5x for 10x rows — sublinear |
| dbf | 200k rows x 3 | 600 000 | 5 795 | 2 571 | 2.25x | 1.00x | 6.4x for 10x rows — sublinear |

The jump in every ratio confirms the 1x numbers were setup-bound; per-row
rates emerge at scale (ODBC, delta-eval over delta-rows: sqlite3 ~3.6 µs/row,
ACE Access ~4.7 µs/row, ACE xls ~7.5 µs/row, ACE dBASE ~9.2 µs/row, ACE
Excel-xlsb ~16.8 µs/row). Driverless dbf remains the best showing at 2.25x.

**xlsb superlinearity — found, fixed, verified.** The first scaling pass
measured 17.6x time for 10x rows while every other reader scaled linearly.
Cause: the cells->table stage built a Record-as-dictionary row map whose
field-lookup cost grows with field count. Commit `61cb250` replaces it with
a linear run walk over the buffered cell list; this pass confirms 10.1x for
10x rows and a 1.8x faster 100k-row decode (40.7 s -> 22.9 s eval), with the
full test suite passing. The first pass had also suggested mild sqlite3
superlinearity (14.3x); with both scales measured in one session it is 9.7x
— that one was cross-session drift, not code.

## Environments

| machine | cpu | ram | disk | os | power | office | drivers | date |
|---|---|---:|---|---|---|---|---|---|
| WOOM | i7-1260P, 12c/16t | 31.7 GB | Samsung PM9A1 NVMe | Win 11 Pro 26200 | Balanced | 16.0.20131 | sqliteodbc 0.99991 · ACE 16.0.20131 | 2026-07-21 |

Drift note: on its first day this machine sped up continuously as post-setup
background work finished (trivial query 3.9 -> 2.4 s, sqlite3 driverless
eval 18.4 -> 11.5 s between morning and evening — same code, same file).
Absolute times are only comparable within one session; **the ratios are the
portable number**, and scaling multiples must come from same-session runs.
One transient spike during the Office-install window made a single xls
decode take ~800 s; it never reproduced.

## Method

Both sides evaluate the same fold — every cell decoded, nothing lazy
survives:

```
List.Sum(List.Transform(Table.ToRows(t), List.NonNullCount))
```

- **Same bytes.** The driverless side reads each fixture embedded in the
  test mez; the ODBC side reads the identical file from disk (sha256
  recorded per pairing in the results JSON).
- **Same harness.** One `PQTest.exe compare` process per run (Power Query
  SDK tools 2.155.2); median of 5 timed runs after 1 untimed warmup, warm
  file cache. A trivial query timed the same way isolates process overhead;
  its median is subtracted for eval-only.
- **Correctness gate.** A pairing aborts unless both sides return the
  identical value.
- **ACE-real fixtures.** ACE rejects minimal synthetic workbook files, so
  the xls/xlsb/access fixtures are authored through the real engines
  (`make_ace_fixtures.ps1`: Excel COM for the workbooks, DAO for the .accdb
  — the suite's first bulk Access fixture).
- **Header-row rule.** The ACE Excel driver unconditionally consumes row 1
  as column names (`FirstRowHasNames` is not accepted as a connection
  attribute), so the ACE workbook fixtures carry a header row and the
  driverless queries `Table.Skip(1)` — both sides fold exactly the same
  data cells.
- **Settling discipline.** First pass on a fresh machine state is discarded
  (post-install background work distorts it — measured up to 200x once);
  measure only after times stabilize.
- **Reproduce:** `make_perf_fixtures.py` -> `make_ace_fixtures.ps1` (needs
  Office) -> `build-mez.ps1` -> `run-odbc-benchmark.ps1 [-Label 10x]`.
  Pairings whose driver or fixture is absent are recorded as skipped, so
  partial environments still produce a valid results file.

## Reading the result

Two regimes, one story. **On small files** — the size most ad-hoc imports
actually are — ODBC's per-connection setup dominates its own decode, so
driverless sits at 1.0–2.9x against ACE (dbf at outright parity) and can win
on wall clock. **At scale**, per-row cost takes over and the native drivers
win everywhere: 2.3x (dbf) to 15x (sqlite3), the price of decoding in
interpreted M versus compiled C. What the driverless column buys at either
scale: zero installation (this machine needed a manual driver install *and*
a full Office install before the ODBC column could exist), no bitness or
registry concerns, and identical behaviour anywhere M runs — including
services where drivers cannot be installed at all. Pick by file size and
environment, not by a single headline number.

The benchmark also pays for itself as a scaling regression test: its first
10x pass exposed a real superlinear path in the xlsb reader that no
functional fixture had caught, fixed the same day.

## Pairings — status

| format | driverless reader | driver counterpart | status |
|---|---|---|---|
| sqlite3 | `Sqlite3.Database` | sqliteodbc (Werner) | measured |
| xlsb | `Xlsb.Workbook` | ACE Excel ODBC | measured (post-fix) |
| xls | `Xls.Workbook` | ACE Excel ODBC | measured |
| access | `AccessReader.Database` | ACE Access ODBC | measured |
| dbf | `Dbf.Table` | ACE dBASE ODBC | measured |
| avro · evtx · stata · spss · matlab · gpkg · mbtiles | — | no mainstream ODBC counterpart | driverless-only |

Next: more machines — each adds an Environments row and results files
(`<hostname>` and `<hostname>-10x`) to the repo.

---

Harness: `tests/perf/run-odbc-benchmark.ps1` on branch `odbc-vs-driverless` ·
results committed per machine under `tests/perf/results/` · timings are wall
clock, not micro-benchmarks — treat single-digit-percent differences as
noise.
