# ODBC vs driverless: WOOM-10x

- **machine**: WOOM
- **timestamp**: 2026-07-21T13:07:55+01:00
- **cpu**: 12th Gen Intel(R) Core(TM) i7-1260P
- **cores**: 12
- **logicalCpus**: 16
- **ramGB**: 31.7
- **disk**: SAMSUNG MZVL21T0HCLR-00BL7 (SSD, NVMe)
- **os**: Microsoft Windows 11 Pro build 26200
- **powerPlan**: Balanced
- **pqTestVersion**: 2.155.2.0
- **office**: 16.0.20131.20154
- **overhead**: 2517 ms median (trivial query; subtracted for eval-only)

Median of 5 runs, wall clock per PQTest.exe process, warm cache.

| pairing | output | driverless wall (ms) | odbc wall (ms) | driverless eval (ms) | odbc eval (ms) | eval ratio |
|---|---:|---:|---:|---:|---:|---:|
| sqlite3 | 8000000 | 117603 | 10081 | 115086 | 7564 | 15.21x |
| xlsb | 400000 | 25386 | 4808 | 22869 | 2291 | 9.98x |
| xls | 195000 | 10857 | 3626 | 8340 | 1109 | 7.52x |
| access | 800000 | 13384 | 4132 | 10867 | 1615 | 6.73x |
| dbf | 600000 | 8312 | 5088 | 5795 | 2571 | 2.25x |

