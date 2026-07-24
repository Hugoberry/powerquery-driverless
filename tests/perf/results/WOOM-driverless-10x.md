# Driverless-only refresh: WOOM-driverless-10x

- **machine**: WOOM
- **timestamp**: 2026-07-24T13:43:58+01:00
- **cpu**: 12th Gen Intel(R) Core(TM) i7-1260P
- **cores**: 12
- **logicalCpus**: 16
- **ramGB**: 31.7
- **disk**: SAMSUNG MZVL21T0HCLR-00BL7 (SSD, NVMe)
- **os**: Microsoft Windows 11 Pro build 26200
- **powerPlan**: Balanced
- **pqTestVersion**: 2.155.2.0
- **office**: 16.0.20131.20154
- **overhead**: 2717 ms median (trivial query)
- **machine drift vs prior full run**: 0.919 x (median over controls: xlsb, access, dbf, avro, evtx, stata, spss, matlab, gpkg, mbtiles)

Native evals are RETAINED from the prior full run (not re-timed). Ratios vs native cross sessions; divide by machine drift to normalise.

| pairing | ctl | output | driverless eval (ms) | prior dl eval (ms) | drift vs prior | native (engine: eval ms, ratio) |
|---|:--:|---:|---:|---:|---:|---|
| sqlite3 |  | 8000000 | 113498 | 115086 | 0.986x | odbc: 7564, 15.01x |
| xlsb | • | 400000 | 21381 | 22869 | 0.935x | odbc: 2291, 9.33x |
| xls |  | 195000 | 5935 | 8340 | 0.712x | odbc: 1109, 5.35x |
| access | • | 800000 | 10725 | 10867 | 0.987x | odbc: 1615, 6.64x |
| dbf | • | 600000 | 5208 | 5795 | 0.899x | odbc: 2571, 2.03x |
| avro | • | 6000000 | 9635 | 9619 | 1.002x | python: 2268, 4.25x |
| evtx | • | 240000 | 18506 | 20138 | 0.919x | python: 73, 253.51x |
| stata | • | 2000000 | 10823 | 11596 | 0.933x | python: 169, 64.04x · r: 603, 17.95x |
| spss | • | 1600000 | 12988 | 15947 | 0.814x | python: 858, 15.14x · r: 506, 25.67x |
| matlab | • | 1200000 | 2788 | 3783 | 0.737x | python: 510, 5.47x |
| gpkg | • | 600000 | 14317 | 16867 | 0.849x | python: 127, 112.73x |
| mbtiles | • | 41281308 | 6628 | 8475 | 0.782x | python: 394, 16.82x |

