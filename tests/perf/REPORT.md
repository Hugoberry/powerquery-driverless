# Native decode vs driverless connector

The same full-decode workload, the same file, the same harness — once through
a native decoder, once through the pure-M driverless reader. Two families of
native decoder are covered: **ODBC drivers** (part 1, for the formats one
exists for) and **Python/R libraries** (part 2, for the seven formats with no
mainstream ODBC driver). This report grows as pairings and machines are
added; per-machine raw data lives in
`tests/perf/results/<hostname>[-<label>].json+md`.

Updated **24 Jul 2026** · 1 machine · 5 ODBC + 9 script pairings · 2 scales
(1x and 10x). Parts 1 and 2 below are the 21 Jul same-session native baselines
(`61cb250` xlsb fix throughout); the **driverless refresh (24 Jul)** section
directly beneath re-times only the pure-M side after two readers changed, and
adds an integer-path A/B for the sqlite3 reader.

---

# Driverless refresh — 24 Jul 2026

Two readers changed after the 21 Jul baseline: sqlite3's `DecodeValue`
(`e3350e5`, integer serial types now dispatch to hoisted `BinaryFormat` readers)
and xls's grid assembly (`dbe95e5`, the records-as-dictionary path replaced with
a buffered run-cursor). Nothing else did. So this pass re-times **only the
driverless side** of all 12 readers, keeps the 21 Jul native evals, and uses the
ten unchanged readers as **drift controls**: the median of their new/old
driverless ratio is the machine-speed factor everything else is read against.
Harness: `run-driverless-benchmark.ps1` (driverless-only, retains native from the
prior full run). Raw data: `results/WOOM-driverless[-10x].json+md`.

## The two headline findings

- **sqlite3 on `bulk.db` is unchanged** — 0.994x (1x) / 0.986x (10x) vs the
  21 Jul driverless eval, inside the machine drift. This is expected and correct:
  `e3350e5` only touches integer serial types 1–6, and the standard fixture
  stores its integers as a rowid and 0/1 (serial-type specials 8/9), so the
  rewritten path never runs. The change is a correctness fix there, not a speedup.
- **sqlite3 on integer-heavy data is ~11% faster** — the win the standard
  fixture cannot show. A dedicated fixture (`bulk-int.db`, 300k rows × six INTEGER
  columns spanning serial types 1–6, signs mixed) was A/B'd old-code vs new-code
  in one session:

  | sqlite3 code | integer-decode eval | fold | value checksum |
  |---|---:|---:|---:|
  | old — `IntBE` (`Binary.ToList` accumulate + `Number.Power` sign) | 28 828 ms | 2 100 000 | 23 283 749 964 |
  | new — hoisted `BinaryFormat.SignedInteger16/32/64` dispatch | 25 784 ms | 2 100 000 | 23 283 749 964 |

  Same value out of both (fold and a mod-1e6 checksum reconstructed from a correct
  decode), so the rewrite is value-neutral; the new dispatch is **1.12x faster
  (−10.6%)** per integer cell. Harness: `ab-sqlite-intdecode.ps1`.

- **xls got materially faster** (the `dbe95e5` grid port, not sqlite): driverless
  eval 0.833x (1x) / 0.712x (10x) vs 21 Jul — roughly 22% beyond machine drift at
  10x — which narrows its gap to the ACE Excel driver from **7.52x to 5.35x**.

## Refreshed driverless evals (WOOM, 24 Jul 2026)

Driverless eval only (median of 5, minus the trivial-query overhead). Native
evals are **retained** from 21 Jul (not re-timed); the ratio is fresh
driverless over that retained native. "drift" is new/old driverless eval — for a
control reader it is pure machine speed; the control median is the yardstick.

**10x — the meaningful scale** (overhead 2 717 ms; control-median drift **0.919x**):

| pairing | ctl | driverless eval (ms) 24 Jul | 21 Jul | drift | retained native eval (ms) | ratio vs native |
|---|:--:|---:|---:|---:|---:|---:|
| sqlite3 |   | 113 498 | 115 086 | 0.986x | 7 564 (odbc) | 15.01x |
| xls     |   | 5 935  | 8 340  | **0.712x** | 1 109 (odbc) | 5.35x |
| xlsb    | • | 21 381 | 22 869 | 0.935x | 2 291 (odbc) | 9.33x |
| access  | • | 10 725 | 10 867 | 0.987x | 1 615 (odbc) | 6.64x |
| dbf     | • | 5 208  | 5 795  | 0.899x | 2 571 (odbc) | 2.03x |
| avro    | • | 9 635  | 9 619  | 1.002x | 2 268 (py)   | 4.25x |
| evtx    | • | 18 506 | 20 138 | 0.919x | 73 (py)      | 253.5x |
| stata   | • | 10 823 | 11 596 | 0.933x | 169 py · 603 r | 64.0x · 18.0x |
| spss    | • | 12 988 | 15 947 | 0.814x | 858 py · 506 r | 15.1x · 25.7x |
| matlab  | • | 2 788  | 3 783  | 0.737x | 510 (py)     | 5.47x |
| gpkg    | • | 14 317 | 16 867 | 0.849x | 127 (py)     | 112.7x |
| mbtiles | • | 6 628  | 8 475  | 0.782x | 394 (py)     | 16.8x |

Every fresh output matched its 21 Jul value exactly (the runner's regression
gate), so these are like-for-like. The two non-control readers separate cleanly:
xls at 0.712x sits well below the 0.919 control median (real code win), sqlite3
at 0.986x sits just above it (no change on this fixture). The controls span
0.74–1.00x around the 0.919 median — unchanged code, so that spread is machine
noise/thermal, and it is why only a gap the size of xls's is called a win.

**1x — setup-bound, kept for completeness** (overhead 2 519 ms; control-median
drift **0.974x**): sqlite3 11 817 ms (0.994x, flat), xls 1 078 ms (0.833x,
faster), the rest within a noisier ±25% control band (1x evals are small, so
overhead-subtraction dominates — the report's standing caveat). Full data in
`results/WOOM-driverless.json`.

## How to read the refresh against Parts 1–2

The native columns and their ratios in Parts 1–2 are the 21 Jul **same-session**
truth. This refresh changes only two driverless numbers of interest — xls (now
~29% faster at 10x) and sqlite3-on-integers (the A/B, +11%) — and leaves the
qualitative picture intact: driverless trades decode throughput for zero install,
native wins at scale, the gaps are order-of-magnitude for the script formats. The
retained-native ratios above are within ~10% of a same-session figure (the
machine drifted ~8% at 10x); they are not restated as portable truth, they show
that xls's gap narrowed and sqlite3's held.

---

# Part 1 — ODBC driver vs driverless connector

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

Script engines (part 2), same machine: PQTest SDK 2.155.2 · Python 3.12.10
(pandas 3.0.3, fastavro 1.12.2, pyreadstat 1.3.5, scipy 1.18.0, pyogrio
0.13.0, evtx 0.12.1) · R 4.6.1 (haven 2.5.5), via the Power BI Desktop script
providers (SETUP.md §3).

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

---

# Part 2 — native library vs driverless connector

The seven formats with no mainstream ODBC driver — avro, evtx, stata, spss,
matlab, gpkg, mbtiles — are compared instead against the best native library,
driven through the Power Query engine's Python/R script providers (the same
path `Python.Execute` / `R.Execute` use). Same harness, same file, one
`PQTest.exe` process per run; the script reads the file from disk and prints
one parity integer that must match the driverless reader's fold. stata and
spss are paired against two libraries each (pandas/pyreadstat and R haven), so
nine pairings in all. Harness: `tests/perf/run-script-benchmark.ps1`.

## Key numbers (10x scale)

- **Native libraries win by 4x–276x** on decode-only time — a far wider gap
  than ODBC's 2–15x, because these are compiled bulk decoders (GDAL, Rust,
  pandas' C core) with no per-row bridging cost.
- **The two extremes are the predicted ones.** evtx **276x** (Rust pyevtx-rs
  vs interpreted binary-XML template expansion in M) and gpkg **133x**
  (GDAL/pyogrio WKB decode). The C-backed tabular libraries sit 7x–69x ahead.
- **Import + marshalling floor: ~3.4–4.5 s per eval** — PQTest startup +
  interpreter launch + library import + CSV/RData round-trip. This is the
  script-side analog of the ODBC ~1 s setup floor, but roughly 4x larger, so
  at 1x scale every C-backed decode finishes inside it. The 10x figures are
  the meaningful ones.
- **Output parity: 9/9.** Eight pairings match exact non-null cell/element
  counts (Tier 1); evtx matches the event count (Tier 2 — the reader flattens
  each event into its own column set while pyevtx-rs yields raw XML, so cells
  cannot match). The runner aborts on any mismatch, both scales.

Both scales were measured back-to-back on 21 Jul in one session, so the
scaling reading is drift-free.

## Results — 10x fixtures (WOOM, 21 Jul 2026)

Median of 5 runs, wall clock per PQTest.exe process, warm cache. Driverless
eval subtracts the trivial-query floor (2 840 ms this session); native eval
subtracts the per-pairing imports-only floor (shown). Eval ratios > 1 favour
the native library — here, always.

| pairing | native library | tier | parity | driverless eval (ms) | native eval (ms) | imports floor (ms) | eval ratio |
|---|---|---|---:|---:|---:|---:|---:|
| avro | fastavro | 1 | 6 000 000 | 9 619 | 2 268 | 3 777 | 4.24x |
| evtx | pyevtx-rs | 2 | 15 000\* | 20 138 | 73 | 3 913 | **275.86x** |
| stata | pandas | 1 | 2 000 000 | 11 596 | 169 | 3 787 | 68.62x |
| stata | R haven | 1 | 2 000 000 | 11 596 | 603 | 3 391 | 19.23x |
| spss | pyreadstat | 1 | 1 600 000 | 15 947 | 858 | 4 232 | 18.59x |
| spss | R haven | 1 | 1 600 000 | 15 947 | 506 | 4 009 | 31.52x |
| matlab | scipy | 1 | 1 200 000 | 3 783 | 510 | 4 515 | 7.42x |
| gpkg | pyogrio | 1 | 600 000 | 16 867 | 127 | 4 456 | **132.81x** |
| mbtiles | sqlite3 + gzip | 1 | 41 281 308 | 8 475 | 394 | 4 409 | 21.51x |

\* evtx parity is the event count (Tier 2). The driverless side still decodes
in full — its flattened fold is 240 000 cells at 10x — and that full decode is
what is timed; only the parity gate uses the structural count.

Two library-vs-library notes fall out of the double pairing: pandas reads the
500k-row `.dta` **3.6x faster** than R haven (169 vs 603 ms), while haven
reads the 400k-row `.sav` **1.7x faster** than pyreadstat (506 vs 858 ms).

## 1x scale is floor-bound

At 1x fixtures the imports floor (~3.6–5.3 s) swamps the decode: five of the
nine native evals finish inside the noise and clamp to ~0, so their ratios
are not meaningful. Only avro (6.3x), stata-R (9.4x), spss-Python (10.6x) and
mbtiles (1.9x) resolve above the floor — the readers whose native side does
real per-record Python work (fastavro object build, haven, pyreadstat, the
per-tile gzip loop) rather than a pure C bulk read. Driverless eval scales
broadly linearly 1x→10x (4.8x–9.4x for 10x rows/records/vars; the 1x term is
itself overhead-sensitive). Full 1x data: `results/WOOM-scripts.json`.

## Reading the result

Where a mature native library exists, it decodes these formats far faster
than interpreted M — 4x for avro, ~20–70x for the tabular stats formats,
130–280x for the GDAL- and Rust-backed readers. That is the honest cost of a
zero-dependency pure-M reader: it trades decode throughput for running
**anywhere M runs, with nothing to install** — no Python, no R, no GDAL, no
gateway, no bitness or provider-registration concerns. This benchmark's own
native column could not exist until a full Power BI Desktop install had
registered the script providers (SETUP.md §3); the driverless column needs
only the mez. For a one-off import of a modest file the difference is
sub-second and moot; for repeated decode of large files in an environment
that can carry the toolchain, the native library is the right tool. Pick by
file size, repetition, and whether the environment can hold the dependency.

## Pairings — status

| format | driverless reader | native counterpart | status |
|---|---|---|---|
| sqlite3 | `Sqlite3.Database` | sqliteodbc (Werner) | measured (ODBC) |
| xlsb | `Xlsb.Workbook` | ACE Excel ODBC | measured (ODBC, post-fix) |
| xls | `Xls.Workbook` | ACE Excel ODBC | measured (ODBC) |
| access | `AccessReader.Database` | ACE Access ODBC | measured (ODBC) |
| dbf | `Dbf.Table` | ACE dBASE ODBC | measured (ODBC) |
| avro | `Avro.Document` | fastavro (Python) | measured (script) |
| evtx | `Evtx.Document` | pyevtx-rs (Python) | measured (script) |
| stata | `Stata.Document` | pandas · R haven | measured (script) |
| spss | `Spss.Document` | pyreadstat · R haven | measured (script) |
| matlab | `Matlab.Document` | scipy (Python) | measured (script) |
| gpkg | `Gpkg.Database` | pyogrio/GDAL (Python) | measured (script) |
| mbtiles | `Mbtiles.Document` | sqlite3 + gzip (Python) | measured (script) |

Next: more machines — each adds an Environments row and results files
(`<hostname>[-scripts][-10x]`) to the repo.

---

Harness: `tests/perf/run-odbc-benchmark.ps1` (part 1) and
`run-script-benchmark.ps1` (part 2) · results committed per machine under
`tests/perf/results/` · timings are wall clock, not micro-benchmarks — treat
single-digit-percent differences as noise.
