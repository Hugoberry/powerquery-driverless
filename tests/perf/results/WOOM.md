# ODBC vs driverless: WOOM

- **machine**: WOOM
- **timestamp**: 2026-07-20T19:31:21+01:00
- **cpu**: 12th Gen Intel(R) Core(TM) i7-1260P
- **cores**: 12
- **logicalCpus**: 16
- **ramGB**: 31.7
- **disk**: SAMSUNG MZVL21T0HCLR-00BL7 (SSD, NVMe)
- **os**: Microsoft Windows 11 Pro build 26200
- **powerPlan**: Balanced
- **pqTestVersion**: 2.155.2.0
- **odbcDriver**: sqliteodbc 0.99991 (C:\WINDOWS\system32\sqlite3odbc.dll)
- **office**: none
- **fixture**: bulk.db, 5.8 MB, sha256 6980ed70eb871c27b6086c6b19d45512ee7831d2459b657dca84c65b0819ed9a

Median of 5 runs, wall clock per PQTest.exe process, warm cache. Eval = median minus trivial-query overhead.

| case | median (ms) | eval-only (ms) | runs (ms) |
|---|---:|---:|---|
| overhead (trivial query) | 3916 | - | 3894, 4030, 3877, 3916, 4171 |
| sqlite3 driverless | 22358 | 18442 | 21849, 22812, 22358, 22279, 22403 |
| sqlite3 odbc | 4688 | 772 | 5211, 4732, 4688, 4508, 4526 |

Wall ratio driverless/odbc: 4.77x - eval-only ratio: 23.89x. Both cases returned 800000.

