# ODBC vs driverless: WOOM

- **machine**: WOOM
- **timestamp**: 2026-07-20T20:47:53+01:00
- **cpu**: 12th Gen Intel(R) Core(TM) i7-1260P
- **cores**: 12
- **logicalCpus**: 16
- **ramGB**: 31.7
- **disk**: SAMSUNG MZVL21T0HCLR-00BL7 (SSD, NVMe)
- **os**: Microsoft Windows 11 Pro build 26200
- **powerPlan**: Balanced
- **pqTestVersion**: 2.155.2.0
- **office**: 16.0.20131.20154
- **overhead**: 2433 ms median (trivial query; subtracted for eval-only)

Median of 5 runs, wall clock per PQTest.exe process, warm cache.

| pairing | output | driverless wall (ms) | odbc wall (ms) | driverless eval (ms) | odbc eval (ms) | eval ratio |
|---|---:|---:|---:|---:|---:|---:|
| sqlite3 | 800000 | 13950 | 3482 | 11517 | 1049 | 10.98x |
| xlsb | 40000 | 4743 | 3477 | 2310 | 1044 | 2.21x |
| xls | 24000 | 3676 | 3412 | 1243 | 979 | 1.27x |
| access | 80000 | 3824 | 3508 | 1391 | 1075 | 1.29x |
| dbf | 60000 | 3328 | 3586 | 895 | 1153 | 0.78x |

