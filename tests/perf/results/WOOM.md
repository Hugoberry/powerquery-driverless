# ODBC vs driverless: WOOM

- **machine**: WOOM
- **timestamp**: 2026-07-21T13:13:34+01:00
- **cpu**: 12th Gen Intel(R) Core(TM) i7-1260P
- **cores**: 12
- **logicalCpus**: 16
- **ramGB**: 31.7
- **disk**: SAMSUNG MZVL21T0HCLR-00BL7 (SSD, NVMe)
- **os**: Microsoft Windows 11 Pro build 26200
- **powerPlan**: Balanced
- **pqTestVersion**: 2.155.2.0
- **office**: 16.0.20131.20154
- **overhead**: 2582 ms median (trivial query; subtracted for eval-only)

Median of 5 runs, wall clock per PQTest.exe process, warm cache.

| pairing | output | driverless wall (ms) | odbc wall (ms) | driverless eval (ms) | odbc eval (ms) | eval ratio |
|---|---:|---:|---:|---:|---:|---:|
| sqlite3 | 800000 | 14471 | 3650 | 11889 | 1068 | 11.13x |
| xlsb | 40000 | 4843 | 3359 | 2261 | 777 | 2.91x |
| xls | 24000 | 3876 | 3265 | 1294 | 683 | 1.89x |
| access | 80000 | 4028 | 3350 | 1446 | 768 | 1.88x |
| dbf | 60000 | 3491 | 3494 | 909 | 912 | 1x |

