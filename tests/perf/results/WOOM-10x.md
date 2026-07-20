# ODBC vs driverless: WOOM-10x

- **machine**: WOOM
- **timestamp**: 2026-07-20T22:20:54+01:00
- **cpu**: 12th Gen Intel(R) Core(TM) i7-1260P
- **cores**: 12
- **logicalCpus**: 16
- **ramGB**: 31.7
- **disk**: SAMSUNG MZVL21T0HCLR-00BL7 (SSD, NVMe)
- **os**: Microsoft Windows 11 Pro build 26200
- **powerPlan**: Balanced
- **pqTestVersion**: 2.155.2.0
- **office**: 16.0.20131.20154
- **overhead**: 3759 ms median (trivial query; subtracted for eval-only)

Median of 5 runs, wall clock per PQTest.exe process, warm cache.

| pairing | output | driverless wall (ms) | odbc wall (ms) | driverless eval (ms) | odbc eval (ms) | eval ratio |
|---|---:|---:|---:|---:|---:|---:|
| sqlite3 | 8000000 | 168870 | 12858 | 165111 | 9099 | 18.15x |
| xlsb | 400000 | 44505 | 6526 | 40746 | 2767 | 14.73x |
| xls | 195000 | 13815 | 4693 | 10056 | 934 | 10.77x |
| access | 800000 | 17251 | 5268 | 13492 | 1509 | 8.94x |
| dbf | 600000 | 10359 | 6248 | 6600 | 2489 | 2.65x |

