#!/usr/bin/env python3
"""Generate .xls (BIFF8) fixtures with xlwt (independent writer).

Outputs into xls/test/ (created if missing):
  types.xls       one sheet, every common cell type incl. dates and formulas
  multisheet.xls  three sheets, second hidden, third empty
  strings.xls     enough unique strings to force SST CONTINUE records
  date1904.xls    1904 date system
"""
import datetime
import os
import sys

import xlwt

OUT = sys.argv[1] if len(sys.argv) > 1 else "xls/test"
os.makedirs(OUT, exist_ok=True)


def save(wb, name):
    path = os.path.join(OUT, name)
    wb.save(path)
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


# ---------------------------------------------------------------- types.xls
wb = xlwt.Workbook(encoding="utf-8")
ws = wb.add_sheet("Types")

date_fmt = xlwt.easyxf(num_format_str="yyyy-mm-dd")
datetime_fmt = xlwt.easyxf(num_format_str="yyyy-mm-dd hh:mm:ss")
time_fmt = xlwt.easyxf(num_format_str="hh:mm:ss")
builtin_date = xlwt.easyxf(num_format_str="M/D/YY")       # builtin ifmt 14 territory
pct_fmt = xlwt.easyxf(num_format_str="0.00%")             # numeric, NOT a date

ws.write(0, 0, "id")
ws.write(0, 1, "text")
ws.write(0, 2, "number")
ws.write(0, 3, "flag")
ws.write(0, 4, "when")

ws.write(1, 0, 1)
ws.write(1, 1, "plain ascii")
ws.write(1, 2, 3.14159)
ws.write(1, 3, True)
ws.write(1, 4, datetime.datetime(2024, 3, 15, 13, 45, 30), datetime_fmt)

ws.write(2, 0, 2)
ws.write(2, 1, "unicodé – 你好")        # forces UTF-16 SST entry
ws.write(2, 2, -273.15)
ws.write(2, 3, False)
ws.write(2, 4, datetime.date(1999, 12, 31), date_fmt)

ws.write(3, 0, 3)
# B4 intentionally empty (gap inside the used range)
ws.write(3, 2, 1234567890)                                 # integer -> RK candidate
ws.write(3, 3, True)
ws.write(3, 4, datetime.time(6, 30, 0), time_fmt)

ws.write(4, 0, 4)
ws.write(4, 1, "x" * 300)                                  # long string
ws.write(4, 2, 0.07, pct_fmt)                              # formatted number, not date
ws.write(4, 3, False)
ws.write(4, 4, datetime.datetime(1900, 2, 28), builtin_date)  # pre-leap-bug date

ws.write(5, 0, 5)
ws.write(5, 1, "formulas")
ws.write(5, 2, xlwt.Formula("C2*2"))                       # cached number formula
ws.write(5, 3, xlwt.Formula("D2"))                         # cached bool formula
ws.write(5, 4, xlwt.Formula('CONCATENATE("a","b")'))       # cached string formula

save(wb, "types.xls")

# ------------------------------------------------------------ multisheet.xls
wb = xlwt.Workbook()
ws1 = wb.add_sheet("First")
ws1.write(0, 0, "alpha")
ws1.write(1, 0, 1.0)
ws2 = wb.add_sheet("Hidden Sheet")
ws2.write(0, 0, "you should only see me when IncludeHiddenSheets=true")
ws2.visibility = 1                                         # hidden
ws3 = wb.add_sheet("Empty")
save(wb, "multisheet.xls")

# --------------------------------------------------------------- strings.xls
# > 8224 bytes of SST payload forces CONTINUE records, including a string that
# straddles the record boundary (xlwt splits mid-string with a fresh grbit).
wb = xlwt.Workbook()
ws = wb.add_sheet("Strings")
ws.write(0, 0, "row")
ws.write(0, 1, "value")
for i in range(400):
    ws.write(i + 1, 0, i)
    ws.write(i + 1, 1, f"unique-string-{i:04d}-" + "abcdefghij" * 3)
save(wb, "strings.xls")

# -------------------------------------------------------------- date1904.xls
wb = xlwt.Workbook()
wb.dates_1904 = 1
ws = wb.add_sheet("Dates1904")
fmt = xlwt.easyxf(num_format_str="yyyy-mm-dd hh:mm:ss")
ws.write(0, 0, "when")
ws.write(1, 0, datetime.datetime(2024, 3, 15, 13, 45, 30), fmt)
ws.write(2, 0, datetime.date(1904, 1, 2), fmt)
save(wb, "date1904.xls")
