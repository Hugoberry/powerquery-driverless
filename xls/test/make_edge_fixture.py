#!/usr/bin/env python3
"""Handcraft edge.xls: BIFF8 records xlwt never emits, inside a CFB container
whose Workbook stream is small enough to land in the mini-stream.

Covers: MULRK (all RK encodings), MULBLANK, BLANK, inline LABEL (compressed and
UTF-16), BOOLERR with real error codes, FORMULA with cached number/string/bool/
error results (+ STRING record), LABELSST, and the CFB mini-stream path.
Validated independently with xlrd."""
import os
import struct
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "xls/test"
os.makedirs(OUT, exist_ok=True)


def rec(rid, payload):
    return struct.pack("<HH", rid, len(payload)) + payload


def xl_str8(s):  # XLUnicodeString, cch is 16-bit
    if all(ord(c) < 256 for c in s):
        return struct.pack("<HB", len(s), 0) + s.encode("latin-1")
    return struct.pack("<HB", len(s), 1) + s.encode("utf-16-le")


def short_str(s):  # ShortXLUnicodeString, cch is 8-bit
    return struct.pack("<BB", len(s), 0) + s.encode("latin-1")


def rk_int(v):          # fInt=1, fX100=0
    return (v << 2) | 2 if v >= 0 else ((v + (1 << 30)) << 2 | 2 | (1 << 32)) & 0xFFFFFFFF


def rk_int100(v):       # integer value v/100: fInt=1, fX100=1
    return ((v & 0x3FFFFFFF) << 2) | 3


def rk_float(x):        # top 30 bits of the double: fInt=0, fX100=0
    (bits,) = struct.unpack("<Q", struct.pack("<d", x))
    return (bits >> 34) << 2


def rk_float100(x):     # double / 100
    (bits,) = struct.unpack("<Q", struct.pack("<d", x))
    return ((bits >> 34) << 2) | 1


def signed_rk_int(v):
    return ((v & 0x3FFFFFFF) << 2) | 2


# ------------------------------------------------------------- BIFF8 stream
XF_GENERAL = 16  # first cell XF after the 16 style XFs
XF_DATE = 17

globals_recs = [
    rec(0x0809, struct.pack("<HHHHII", 0x0600, 0x0005, 0x0DBB, 0x07CC, 0, 0)),  # BOF globals
    rec(0x0042, struct.pack("<H", 1200)),                                       # CODEPAGE utf-16
    rec(0x0022, struct.pack("<H", 0)),                                          # DATEMODE 1900
    rec(0x041E, struct.pack("<H", 164) + xl_str8("yyyy\\-mm\\-dd")),            # FORMAT ifmt 164
]
# 16 style XFs then 2 cell XFs (general, date). 20 bytes: ifnt, ifmt, flags, rest.
def xf(ifmt, style):
    flags = 0xFFF5 if style else 0x0001
    return rec(0x00E0, struct.pack("<HHH", 0, ifmt, flags) + b"\x20" + b"\x00" * 13)

for i in range(16):
    globals_recs.append(xf(0, True))
globals_recs.append(xf(0, False))
globals_recs.append(xf(164, False))

sst_strings = ["from the shared string table", "ünïcode ✓"]
sst_payload = struct.pack("<II", 2, 2)
for s in sst_strings:
    if all(ord(c) < 256 for c in s):
        sst_payload += struct.pack("<HB", len(s), 0) + s.encode("latin-1")
    else:
        sst_payload += struct.pack("<HB", len(s), 1) + s.encode("utf-16-le")

# FORMULA cached results
def fml(rw, col, result8, rgce=struct.pack("<BH", 0x1E, 1)):  # rgce = ptgInt 1
    return rec(0x0006, struct.pack("<HHH", rw, col, XF_GENERAL) + result8
               + struct.pack("<HIH", 0x0002, 0, len(rgce)) + rgce)

res_num = struct.pack("<d", 42.5)
res_str = struct.pack("<BBHHH", 0, 0, 0, 0, 0xFFFF)          # string follows in STRING
res_bool = struct.pack("<BBBBHH", 1, 0, 1, 0, 0, 0xFFFF)     # TRUE
res_err = struct.pack("<BBBBHH", 2, 0, 0x2A, 0, 0, 0xFFFF)   # #N/A

sheet_recs = [
    rec(0x0809, struct.pack("<HHHHII", 0x0600, 0x0010, 0x0DBB, 0x07CC, 0, 0)),  # BOF sheet
    rec(0x0200, struct.pack("<IIHHH", 0, 8, 0, 7, 0)),                          # DIMENSIONS
    # r0: MULRK with every RK encoding: 30000, -5, 123.45(int/100), 3.5, 3.14159/100
    rec(0x00BD, struct.pack("<HH", 0, 0)
        + struct.pack("<HI", XF_GENERAL, rk_int(30000))
        + struct.pack("<HI", XF_GENERAL, signed_rk_int(-5))
        + struct.pack("<HI", XF_GENERAL, rk_int100(12345))
        + struct.pack("<HI", XF_GENERAL, rk_float(3.5))
        + struct.pack("<HI", XF_GENERAL, rk_float100(314.159))
        + struct.pack("<H", 4)),
    # r1: BLANK, MULBLANK, then a date-styled RK (serial 45000 = 2023-03-15)
    rec(0x0201, struct.pack("<HHH", 1, 0, XF_GENERAL)),
    rec(0x00BE, struct.pack("<HHHHHH", 1, 1, XF_GENERAL, XF_GENERAL, XF_GENERAL, 3)),
    rec(0x027E, struct.pack("<HHHI", 1, 4, XF_DATE, rk_int(45000))),
    # r2: inline LABELs (compressed + utf16) and LABELSST refs
    rec(0x0204, struct.pack("<HHH", 2, 0, XF_GENERAL) + xl_str8("inline latin")),
    rec(0x0204, struct.pack("<HHH", 2, 1, XF_GENERAL) + xl_str8("inline ünïcode €")),
    rec(0x00FD, struct.pack("<HHHI", 2, 2, XF_GENERAL, 0)),
    rec(0x00FD, struct.pack("<HHHI", 2, 3, XF_GENERAL, 1)),
    # r3: booleans and errors
    rec(0x0205, struct.pack("<HHHBB", 3, 0, XF_GENERAL, 1, 0)),     # TRUE
    rec(0x0205, struct.pack("<HHHBB", 3, 1, XF_GENERAL, 0, 0)),     # FALSE
    rec(0x0205, struct.pack("<HHHBB", 3, 2, XF_GENERAL, 0x07, 1)),  # #DIV/0!
    rec(0x0205, struct.pack("<HHHBB", 3, 3, XF_GENERAL, 0x0F, 1)),  # #VALUE!
    rec(0x0205, struct.pack("<HHHBB", 3, 4, XF_GENERAL, 0x2A, 1)),  # #N/A
    # r4: FORMULA cached results
    fml(4, 0, res_num),
    fml(4, 1, res_str),
    rec(0x0207, xl_str8("cached formula string")),
    fml(4, 2, res_bool),
    fml(4, 3, res_err),
    # r5: NUMBER
    rec(0x0203, struct.pack("<HHH", 5, 0, XF_GENERAL) + struct.pack("<d", 2.718281828)),
    rec(0x000A, b""),
]

g = b"".join(globals_recs)
boundsheet_pos_field = len(g) + 4 + 8 + 4 + len(sst_payload)  # after BOUNDSHEET+SST+EOF... compute below


def build_stream():
    # order: globals, BOUNDSHEET (needs sheet offset), SST, EOF, sheet
    bs_name = short_str("Edge")
    bs_len = 4 + 4 + 2 + len(bs_name)
    sst = rec(0x00FC, sst_payload)
    eof = rec(0x000A, b"")
    sheet = b"".join(sheet_recs)
    sheet_off = len(g) + bs_len + len(sst) + len(eof)
    bs = rec(0x0085, struct.pack("<IH", sheet_off, 0x0000) + bs_name)
    assert len(bs) == bs_len
    return g + bs + sst + eof + sheet


stream = build_stream()
assert len(stream) < 4096, len(stream)  # must exercise the mini-stream

# --------------------------------------------------------------- CFB writer
SECT = 512
MINI = 64
FREE, ENDCHAIN, FATSECT = 0xFFFFFFFF, 0xFFFFFFFE, 0xFFFFFFFD


def pad(b, n):
    return b + b"\x00" * (-len(b) % n)


ministream = pad(stream, MINI)
n_mini = len(ministream) // MINI

# sector plan: [0]=miniFAT, [1..k]=ministream data, [k+1]=directory, [k+2]=FAT
n_ms_sect = (len(ministream) + SECT - 1) // SECT
minifat_sect = 0
ms_first = 1
dir_sect = ms_first + n_ms_sect
fat_sect = dir_sect + 1
n_sect = fat_sect + 1

# miniFAT: chain 0..n_mini-1
minifat = b"".join(struct.pack("<I", i + 1 if i + 1 < n_mini else ENDCHAIN) for i in range(n_mini))
minifat = pad(minifat, SECT)

# FAT
fat = [FREE] * (SECT // 4)
fat[minifat_sect] = ENDCHAIN
for i in range(n_ms_sect):
    fat[ms_first + i] = ms_first + i + 1 if i + 1 < n_ms_sect else ENDCHAIN
fat[dir_sect] = ENDCHAIN
fat[fat_sect] = FATSECT
fat_bytes = b"".join(struct.pack("<I", v) for v in fat)


def direntry(name, etype, start, size, color=1, left=FREE, right=FREE, child=FREE):
    n = name.encode("utf-16-le") + b"\x00\x00"
    return (pad(n, 64)[:64] + struct.pack("<HBB", len(n), etype, color)
            + struct.pack("<III", left, right, child) + b"\x00" * 36
            + struct.pack("<IIH", start, size, 0) + b"\x00" * 2)


directory = (
    direntry("Root Entry", 5, ms_first, len(ministream), child=1)
    + direntry("Workbook", 2, 0, len(stream))
    + direntry("", 0, 0, 0, color=0, left=FREE, right=FREE)
    + direntry("", 0, 0, 0, color=0)
)
assert len(directory) == SECT

header = (
    bytes.fromhex("D0CF11E0A1B11AE1") + b"\x00" * 16
    + struct.pack("<HHHHHHIIIIIIIIII", 0x003E, 0x0003, 0xFFFE, 9, 6, 0, 0, 0,
                  1,          # number of FAT sectors
                  dir_sect,   # first directory sector
                  0, 4096,
                  minifat_sect, 1,   # first miniFAT sector, count
                  ENDCHAIN, 0)       # first DIFAT sector, count
    + struct.pack("<I", fat_sect) + struct.pack("<I", FREE) * 108
)
assert len(header) == SECT

sectors = [b""] * n_sect
sectors[minifat_sect] = minifat
for i in range(n_ms_sect):
    sectors[ms_first + i] = pad(ministream[i * SECT:(i + 1) * SECT], SECT)
sectors[dir_sect] = directory
sectors[fat_sect] = fat_bytes

path = os.path.join(OUT, "edge.xls")
with open(path, "wb") as f:
    f.write(header + b"".join(sectors))
print(f"wrote {path} ({os.path.getsize(path)} bytes, stream {len(stream)} bytes -> mini-stream)")
