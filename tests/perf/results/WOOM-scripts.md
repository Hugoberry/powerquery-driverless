# Script-library vs driverless: WOOM-scripts

- **machine**: WOOM
- **timestamp**: 2026-07-21T19:33:41+01:00
- **cpu**: 12th Gen Intel(R) Core(TM) i7-1260P
- **cores**: 12
- **logicalCpus**: 16
- **ramGB**: 31.7
- **disk**: SAMSUNG MZVL21T0HCLR-00BL7 (SSD, NVMe)
- **os**: Microsoft Windows 11 Pro build 26200
- **powerPlan**: Balanced
- **pqTestVersion**: 2.155.2.0
- **pythonVersion**: 3.12.10
- **pythonLibs**: pandas 3.0.3; fastavro 1.12.2; pyreadstat 1.3.5; scipy 1.18.0; pyogrio 0.13.0; evtx 0.12.1
- **rVersion**: 4.6.1
- **havenVersion**: 2.5.5
- **overhead**: 2635 ms median (trivial query; PQTest process floor)

Median of 5 runs, wall clock per PQTest.exe process, warm cache. Script eval subtracts the per-pairing imports-only floor (PQTest + interpreter launch + import + marshalling); driverless eval subtracts the trivial-query floor.

| pairing | engine | tier | parity | driverless eval (ms) | script eval (ms) | imports floor (ms) | eval ratio |
|---|---|---|---:|---:|---:|---:|---:|
| avro | python | 1 | 600000 | 1323 | 210 | 3600 | 6.3x |
| evtx | python | 2 | 1500 (struct) | 2148 | 1 | 3970 | 2148x |
| stata | python | 1 | 200000 | 1516 | 1 | 4048 | 1516x |
| stata | r | 1 | 200000 | 1516 | 162 | 3525 | 9.36x |
| spss | python | 1 | 160000 | 1942 | 184 | 3770 | 10.55x |
| spss | r | 1 | 160000 | 1942 | 1 | 3565 | 1942x |
| matlab | python | 1 | 120000 | 723 | 1 | 4064 | 723x |
| gpkg | python | 1 | 60000 | 2305 | 1 | 5323 | 2305x |
| mbtiles | python | 1 | 4119116 | 1774 | 951 | 3631 | 1.87x |

