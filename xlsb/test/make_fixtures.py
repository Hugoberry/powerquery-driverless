#!/usr/bin/env python3
"""Generate .xlsb (BIFF12) fixtures with a purpose-built writer, cross-validated
with pyxlsb (independent reader).

Outputs into xlsb/test/:
  types.xlsb      every cell record type, date styles, formulas with cached values
  multisheet.xlsb three sheets, second hidden, third empty
  date1904.xlsb   1904 date system
  stored.xlsb     ZIP entries stored (method 0) instead of deflated
"""
import os
import struct
import sys
import zipfile

OUT = sys.argv[1] if len(sys.argv) > 1 else "xlsb/test"
os.makedirs(OUT, exist_ok=True)

# ------------------------------------------------------------ BIFF12 pieces
def rid_bytes(rid):
    return bytes([rid]) if rid < 0x80 else bytes([rid & 0xFF, rid >> 8])


def var_len(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def rec(rid, payload=b""):
    return rid_bytes(rid) + var_len(len(payload)) + payload


def ws(s):  # XLWideString
    u = s.encode("utf-16-le")
    return struct.pack("<I", len(u) // 2) + u


def rk_int(v):
    return ((v & 0x3FFFFFFF) << 2) | 2


def rk_int100(v):
    return ((v & 0x3FFFFFFF) << 2) | 3


def rk_float(x):
    (bits,) = struct.unpack("<Q", struct.pack("<d", x))
    return (bits >> 34) << 2


def rk_float100(x):
    (bits,) = struct.unpack("<Q", struct.pack("<d", x))
    return ((bits >> 34) << 2) | 1


def cell(rid, col, style, payload=b""):
    return rec(rid, struct.pack("<II", col, style) + payload)


FORMULA_TAIL = struct.pack("<H", 0) + struct.pack("<I", 3) + struct.pack("<BH", 0x1E, 1) + struct.pack("<I", 0)
# grbit, cce=3, ptgInt 1, cb=0


def row(r):
    return rec(0x0000, struct.pack("<II", r, 0) + struct.pack("<H", 300) + b"\x00" * 7)


def sheet_bin(rows, ncols=8):
    rmax = max((r for r, _ in rows), default=0)
    body = [rec(0x0181),
            rec(0x0194, struct.pack("<IIII", 0, rmax, 0, ncols - 1)),  # BrtWsDim
            rec(0x0191)]  # BeginSheetData
    for r, cells in rows:
        body.append(row(r))
        body.extend(cells)
    body += [rec(0x0192), rec(0x0182)]  # EndSheetData, EndSheet
    return b"".join(body)


def workbook_bin(sheets, date1904=False):
    # sheets: list of (name, relid, hsState)
    out = [rec(0x0183)]  # BeginBook
    out.append(rec(0x0199, struct.pack("<II", 1 if date1904 else 0, 0) + ws("")))  # BrtWbProp
    out.append(rec(0x018F))  # BeginBundleShs
    for i, (name, relid, hs) in enumerate(sheets):
        out.append(rec(0x019C, struct.pack("<II", hs, i + 1) + ws(relid) + ws(name)))
    out.append(rec(0x0190))  # EndBundleShs
    out.append(rec(0x0184))  # EndBook
    return b"".join(out)


def sst_bin(strings):
    out = [rec(0x019F, struct.pack("<II", len(strings), len(strings)))]
    for s in strings:
        out.append(rec(0x0013, b"\x00" + ws(s)))
    out.append(rec(0x01A0))
    return b"".join(out)


def styles_bin(fmts, xf_ifmts):
    # fmts: list of (ifmt, code); xf_ifmts: iFmt per cell XF (position = style index)
    out = [rec(0x0296)]  # BeginStyleSheet
    if fmts:
        out.append(rec(0x04E7, struct.pack("<I", len(fmts))))  # BeginFmts
        for ifmt, code in fmts:
            out.append(rec(0x002C, struct.pack("<H", ifmt) + ws(code)))
        out.append(rec(0x04E8))
    out.append(rec(0x04E9, struct.pack("<I", len(xf_ifmts))))  # BeginCellXFs
    for ifmt in xf_ifmts:
        out.append(rec(0x002F, struct.pack("<HHHHH", 0xFFFF, ifmt, 0, 0, 0) + b"\x00" * 6))
    out.append(rec(0x04EA))
    out.append(rec(0x0297))  # EndStyleSheet
    return b"".join(out)


def rels_xml(targets):
    ns = "http://schemas.openxmlformats.org/package/2006/relationships"
    t = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    rows = "".join(
        f'<Relationship Id="{rid}" Type="{t}/{typ}" Target="{tgt}"/>'
        for rid, typ, tgt in targets)
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="{ns}">{rows}</Relationships>'


CONTENT_TYPES = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="bin" ContentType="application/vnd.ms-excel.sheet.binary.macroEnabled.main"/>'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '</Types>')

ROOT_RELS = rels_xml([("rId1", "officeDocument", "xl/workbook.bin")])


def write_xlsb(path, sheets, sst=None, styles=None, date1904=False, method=zipfile.ZIP_DEFLATED):
    """sheets: list of (name, hsState, sheet_binary)"""
    wb_rels = []
    parts = {}
    for i, (name, hs, sbin) in enumerate(sheets):
        rid = f"rId{i + 1}"
        wb_rels.append((rid, "worksheet", f"worksheets/sheet{i + 1}.bin"))
        parts[f"xl/worksheets/sheet{i + 1}.bin"] = sbin
    n = len(sheets)
    if sst is not None:
        wb_rels.append((f"rId{n + 1}", "sharedStrings", "sharedStrings.bin"))
        parts["xl/sharedStrings.bin"] = sst
    if styles is not None:
        wb_rels.append((f"rId{n + 2}", "styles", "styles.bin"))
        parts["xl/styles.bin"] = styles

    def zinfo(name):  # fixed timestamp keeps fixtures byte-reproducible
        zi = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
        zi.compress_type = method
        return zi

    with zipfile.ZipFile(path, "w", method) as z:
        z.writestr(zinfo("[Content_Types].xml"), CONTENT_TYPES)
        z.writestr(zinfo("_rels/.rels"), ROOT_RELS)
        z.writestr(zinfo("xl/workbook.bin"),
                   workbook_bin([(nm, f"rId{i + 1}", hs) for i, (nm, hs, _) in enumerate(sheets)], date1904))
        z.writestr(zinfo("xl/_rels/workbook.bin.rels"), rels_xml(wb_rels))
        for name, data in parts.items():
            z.writestr(zinfo(name), data)
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


# ----------------------------------------------------------------- fixtures
GEN, DATE, DTIME, PCT = 0, 1, 2, 3   # style indices in styles_bin below
STYLES = styles_bin(
    fmts=[(164, "yyyy\\-mm\\-dd hh:mm:ss"), (165, "0.00%")],
    xf_ifmts=[0, 14, 164, 165])      # general, builtin date, custom datetime, percent

SST = ["shared one", "shared twö ✓", "shared three"]

types_rows = [
    (0, [cell(0x07, 0, GEN, struct.pack("<I", 0)),                # isst 0
         cell(0x07, 1, GEN, struct.pack("<I", 1)),                # isst 1 (unicode)
         cell(0x06, 2, GEN, ws("inline string €")),               # BrtCellSt
         cell(0x01, 3, GEN)]),                                    # styled blank
    (1, [cell(0x02, 0, GEN, struct.pack("<I", rk_int(30000))),
         cell(0x02, 1, GEN, struct.pack("<I", rk_int(-5))),
         cell(0x02, 2, GEN, struct.pack("<I", rk_int100(12345))),
         cell(0x02, 3, GEN, struct.pack("<I", rk_float(3.5))),
         cell(0x02, 4, GEN, struct.pack("<I", rk_float100(314.159)))]),
    (2, [cell(0x05, 0, GEN, struct.pack("<d", 2.718281828)),      # real
         cell(0x05, 1, PCT, struct.pack("<d", 0.07)),             # formatted, not a date
         cell(0x02, 2, DATE, struct.pack("<I", rk_int(45000))),   # 2023-03-15
         cell(0x05, 3, DTIME, struct.pack("<d", 45000.573264))]), # datetime serial
    (4, [cell(0x04, 0, GEN, b"\x01"),                             # TRUE (row gap: r3 skipped)
         cell(0x04, 1, GEN, b"\x00"),                             # FALSE
         cell(0x03, 2, GEN, b"\x07"),                             # #DIV/0!
         cell(0x03, 3, GEN, b"\x2a")]),                           # #N/A
    (5, [cell(0x09, 0, GEN, struct.pack("<d", 42.5) + FORMULA_TAIL),
         cell(0x08, 1, GEN, ws("cached formula string") + FORMULA_TAIL),
         cell(0x0A, 2, GEN, b"\x01" + FORMULA_TAIL),
         cell(0x0B, 3, GEN, b"\x2a" + FORMULA_TAIL)]),
]

write_xlsb(os.path.join(OUT, "types.xlsb"),
           [("Types", 0, sheet_bin(types_rows))], sst=sst_bin(SST), styles=STYLES)

multi = [
    ("First", 0, sheet_bin([(0, [cell(0x07, 0, GEN, struct.pack("<I", 0))]),
                            (1, [cell(0x05, 0, GEN, struct.pack("<d", 1.0))])])),
    ("Hidden Sheet", 1, sheet_bin([(0, [cell(0x06, 0, GEN, ws("only with IncludeHiddenSheets"))])])),
    ("Empty", 0, sheet_bin([])),
]
write_xlsb(os.path.join(OUT, "multisheet.xlsb"), multi, sst=sst_bin(["multi"]), styles=STYLES)

d1904_rows = [(0, [cell(0x05, 0, DTIME, struct.pack("<d", 43903.573264)),   # 2024-03-15 13:45:30 in 1904
                   cell(0x02, 1, DATE, struct.pack("<I", rk_int(1)))])]     # 1904-01-02
write_xlsb(os.path.join(OUT, "date1904.xlsb"),
           [("Dates1904", 0, sheet_bin(d1904_rows))], styles=STYLES, date1904=True)

stored_rows = [(0, [cell(0x06, 0, GEN, ws("stored, not deflated")),
                    cell(0x05, 1, GEN, struct.pack("<d", 99.5))])]
write_xlsb(os.path.join(OUT, "stored.xlsb"),
           [("Stored", 0, sheet_bin(stored_rows))], styles=STYLES, method=zipfile.ZIP_STORED)
