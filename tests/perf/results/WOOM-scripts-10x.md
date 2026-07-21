# Script-library vs driverless: WOOM-scripts-10x

- **machine**: WOOM
- **timestamp**: 2026-07-21T20:11:27+01:00
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
- **overhead**: 2840 ms median (trivial query; PQTest process floor)

Median of 5 runs, wall clock per PQTest.exe process, warm cache. Script eval subtracts the per-pairing imports-only floor (PQTest + interpreter launch + import + marshalling); driverless eval subtracts the trivial-query floor.

| pairing | engine | tier | parity | driverless eval (ms) | script eval (ms) | imports floor (ms) | eval ratio |
|---|---|---|---:|---:|---:|---:|---:|
| avro | python | 1 | 6000000 | 9619 | 2268 | 3777 | 4.24x |
| evtx | python | 2 | 15000 (struct) | 20138 | 73 | 3913 | 275.86x |
| stata | python | 1 | 2000000 | 11596 | 169 | 3787 | 68.62x |
| stata | r | 1 | 2000000 | 11596 | 603 | 3391 | 19.23x |
| spss | python | 1 | 1600000 | 15947 | 858 | 4232 | 18.59x |
| spss | r | 1 | 1600000 | 15947 | 506 | 4009 | 31.52x |
| matlab | python | 1 | 1200000 | 3783 | 510 | 4515 | 7.42x |
| gpkg | python | 1 | 600000 | 16867 | 127 | 4456 | 132.81x |
| mbtiles | python | 1 | 41281308 | 8475 | 394 | 4409 | 21.51x |

