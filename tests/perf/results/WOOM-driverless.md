# Driverless-only refresh: WOOM-driverless

- **machine**: WOOM
- **timestamp**: 2026-07-24T13:14:28+01:00
- **cpu**: 12th Gen Intel(R) Core(TM) i7-1260P
- **cores**: 12
- **logicalCpus**: 16
- **ramGB**: 31.7
- **disk**: SAMSUNG MZVL21T0HCLR-00BL7 (SSD, NVMe)
- **os**: Microsoft Windows 11 Pro build 26200
- **powerPlan**: Balanced
- **pqTestVersion**: 2.155.2.0
- **office**: 16.0.20131.20154
- **overhead**: 2519 ms median (trivial query)
- **machine drift vs prior full run**: 0.974 x (median over controls: xlsb, access, dbf, avro, evtx, stata, spss, matlab, gpkg, mbtiles)

Native evals are RETAINED from the prior full run (not re-timed). Ratios vs native cross sessions; divide by machine drift to normalise.

| pairing | ctl | output | driverless eval (ms) | prior dl eval (ms) | drift vs prior | native (engine: eval ms, ratio) |
|---|:--:|---:|---:|---:|---:|---|
| sqlite3 |  | 800000 | 11817 | 11889 | 0.994x | odbc: 1068, 11.06x |
| xlsb | • | 40000 | 1993 | 2261 | 0.881x | odbc: 777, 2.56x |
| xls |  | 24000 | 1078 | 1294 | 0.833x | odbc: 683, 1.58x |
| access | • | 80000 | 1409 | 1446 | 0.974x | odbc: 768, 1.83x |
| dbf | • | 60000 | 948 | 909 | 1.043x | odbc: 912, 1.04x |
| avro | • | 600000 | 1501 | 1323 | 1.135x | python: 210, 7.15x |
| evtx | • | 24000 | 2469 | 2148 | 1.149x | python: 1, 2469x |
| stata | • | 200000 | 1564 | 1516 | 1.032x | python: 1, 1564x · r: 162, 9.65x |
| spss | • | 160000 | 1769 | 1942 | 0.911x | python: 184, 9.61x · r: 1, 1769x |
| matlab | • | 120000 | 666 | 723 | 0.921x | python: 1, 666x |
| gpkg | • | 60000 | 1812 | 2305 | 0.786x | python: 1, 1812x |
| mbtiles | • | 4119116 | 1020 | 1774 | 0.575x | python: 951, 1.07x |

