#!/usr/bin/env python3
"""Generate large fixtures for the CI perf benchmark. Stdlib only.

One bulk fixture per reader that does random access into a binary (the
readers PR #11 converted to Binary.Range slicing), so the benchmark can
show per-reader gains rather than proxying everything through sqlite/dbf.
Access has no synthetic writer and is not covered.

The row counts are deliberately parameters: several readers on pre-#11 code
are quadratic in file position, so baseline runs need modest defaults; bump
them from the workflow_dispatch inputs once the Binary.Range branch lands.

The xlsb writer is a trimmed copy of xlsb/test/make_fixtures.py; the evtx
writer is imported from evtx/test/make_fixtures.py (importable, stdlib);
the dta/sav/mat/xls/avro/gpkg writers are compact stdlib adaptations of the
hand-crafted writers in each reader's test/make_fixtures.py.
"""
import argparse
import datetime
import gzip
import importlib.util
import json
import os
import random
import sqlite3
import struct
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))


# ---------------------------------------------------------------- sqlite

def make_sqlite(path: str, rows: int) -> None:
    if os.path.exists(path):
        os.remove(path)
    con = sqlite3.connect(path)
    con.execute(
        "CREATE TABLE data (id INTEGER PRIMARY KEY, name TEXT, value REAL, flag INTEGER)"
    )
    rng = random.Random(42)
    con.executemany(
        "INSERT INTO data VALUES (?,?,?,?)",
        ((i, f"row-{i:07d}", rng.random() * 1000, i % 2) for i in range(rows)),
    )
    con.commit()
    con.close()


# ---------------------------------------------------------------- dbf

def make_dbf(path: str, rows: int) -> None:
    # dBASE III: ID N(10,0), NAME C(20), VALUE N(12,2)
    fields = [(b"ID", b"N", 10, 0), (b"NAME", b"C", 20, 0), (b"VALUE", b"N", 12, 2)]
    reclen = 1 + sum(f[2] for f in fields)
    header_len = 32 + 32 * len(fields) + 1
    rng = random.Random(42)
    today = datetime.date(2026, 1, 1)
    with open(path, "wb") as f:
        f.write(
            struct.pack(
                "<B3BLHH20x",
                0x03,
                today.year - 1900,
                today.month,
                today.day,
                rows,
                header_len,
                reclen,
            )
        )
        for name, ftype, flen, fdec in fields:
            f.write(struct.pack("<11sc4xBB14x", name, ftype, flen, fdec))
        f.write(b"\x0D")
        for i in range(rows):
            rec = (
                b" "
                + str(i).rjust(10).encode()
                + f"row-{i:07d}".ljust(20).encode()
                + f"{rng.random() * 1000:.2f}".rjust(12).encode()
            )
            f.write(rec)
        f.write(b"\x1A")


# ---------------------------------------------------------------- stata (dta 114, LSF)
# Adapted from the legacy1252.dta writer in stata/test/make_fixtures.py.

def make_stata(path: str, rows: int) -> None:
    E = "<"
    hdr = struct.pack(f"{E}BBBBhi", 114, 2, 1, 0, 4, rows)  # LSF, 4 vars
    hdr += b"perf bulk fixture".ljust(81, b"\0")
    hdr += b"01 Jan 2026 00:00\0"
    typlist = bytes([255, 20, 255, 251])                    # double, str20, double, byte
    names = [b"id", b"name", b"value", b"flag"]
    varlist = b"".join(n.ljust(33, b"\0") for n in names)
    srtlist = struct.pack(f"{E}5h", 0, 0, 0, 0, 0)
    fmtlist = b"".join(f.ljust(49, b"\0") for f in [b"%10.0g", b"%20s", b"%12.2f", b"%8.0g"])
    lbllist = b"\0" * 33 * 4
    varlabels = b"\0" * 81 * 4
    expansion = b"\x00" + struct.pack(f"{E}i", 0)           # empty, terminator only
    rng = random.Random(42)
    with open(path, "wb") as f:
        f.write(hdr + typlist + varlist + srtlist + fmtlist + lbllist
                + varlabels + expansion)
        for i in range(rows):
            f.write(struct.pack(f"{E}d", float(i)))
            f.write(f"row-{i:07d}".encode().ljust(20, b"\0"))
            f.write(struct.pack(f"{E}d", rng.random() * 1000))
            f.write(struct.pack(f"{E}b", i % 2))


# ---------------------------------------------------------------- spss (sav, uncompressed)
# Adapted from the legacy1252.sav writer in spss/test/make_fixtures.py.

SYSMIS = struct.unpack("<d", struct.pack("<Q", 0xFFEFFFFFFFFFFFFF))[0]


def _sav_fmt(ftype, width, dec=0):
    return (ftype << 16) | (width << 8) | dec


def _sav_var(vtype, name, print_fmt, write_fmt):
    out = struct.pack("<iiiiii", 2, vtype, 0, 0, print_fmt, write_fmt)
    out += name.ljust(8)[:8].encode("ascii")
    return out


def _sav_continuation():
    return struct.pack("<iiiiii", 2, -1, 0, 0, 0, 0) + b" " * 8


def _sav_info(subtype, size, payload):
    return struct.pack("<iiii", 7, subtype, size, len(payload) // size) + payload


def make_spss(path: str, rows: int) -> None:
    name_w = 16  # two 8-byte elements
    case_size = 1 + name_w // 8 + 1 + 1
    body = b"$FL2"
    body += b"@(#) SPSS DATA FILE driverless perf writer".ljust(60)
    body += struct.pack("<iiiii", 2, case_size, 0, 0, rows)  # compression 0
    body += struct.pack("<d", 100.0)
    body += b"01 Jan 26" + b"00:00:00"
    body += b"perf bulk fixture".ljust(64)[:64]
    body += b"\x00" * 3
    body += _sav_var(0, "ID", _sav_fmt(5, 8, 0), _sav_fmt(5, 8, 0))
    body += _sav_var(name_w, "NAME", _sav_fmt(1, name_w), _sav_fmt(1, name_w))
    body += _sav_continuation()
    body += _sav_var(0, "VALUE", _sav_fmt(5, 8, 2), _sav_fmt(5, 8, 2))
    body += _sav_var(0, "FLAG", _sav_fmt(5, 8, 0), _sav_fmt(5, 8, 0))
    ints = struct.pack("<8i", 1, 0, 0, 1, 1, 1, 2, 1252)
    flts = struct.pack("<3d", SYSMIS,
                       struct.unpack("<d", struct.pack("<Q", 0x7FEFFFFFFFFFFFFF))[0],
                       SYSMIS)
    body += _sav_info(3, 4, ints) + _sav_info(4, 8, flts)
    body += struct.pack("<ii", 999, 0)
    rng = random.Random(42)
    with open(path, "wb") as f:
        f.write(body)
        for i in range(rows):
            f.write(struct.pack("<d", float(i)))
            f.write(f"row-{i:07d}".encode().ljust(name_w))
            f.write(struct.pack("<d", rng.random() * 1000))
            f.write(struct.pack("<d", float(i % 2)))


# ---------------------------------------------------------------- xlsb (BIFF12)
# Trimmed copy of the purpose-built writer in xlsb/test/make_fixtures.py.

def _rid_bytes(rid):
    return bytes([rid]) if rid < 0x80 else bytes([rid & 0xFF, rid >> 8])


def _var_len(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _rec(rid, payload=b""):
    return _rid_bytes(rid) + _var_len(len(payload)) + payload


def _ws(s):  # XLWideString
    u = s.encode("utf-16-le")
    return struct.pack("<I", len(u) // 2) + u


def _cell(rid, col, style, payload=b""):
    return _rec(rid, struct.pack("<II", col, style) + payload)


def _xlsb_row(r):
    return _rec(0x0000, struct.pack("<II", r, 0) + struct.pack("<H", 300) + b"\x00" * 7)


def _xlsb_sheet(rows, ncols):
    rmax = max((r for r, _ in rows), default=0)
    body = [_rec(0x0181),
            _rec(0x0194, struct.pack("<IIII", 0, rmax, 0, ncols - 1)),
            _rec(0x0191)]
    for r, cells in rows:
        body.append(_xlsb_row(r))
        body.extend(cells)
    body += [_rec(0x0192), _rec(0x0182)]
    return b"".join(body)


def _xlsb_workbook(sheets):
    out = [_rec(0x0183),
           _rec(0x0199, struct.pack("<II", 0, 0) + _ws("")),
           _rec(0x018F)]
    for i, (name, relid, hs) in enumerate(sheets):
        out.append(_rec(0x019C, struct.pack("<II", hs, i + 1) + _ws(relid) + _ws(name)))
    out += [_rec(0x0190), _rec(0x0184)]
    return b"".join(out)


def _xlsb_styles():
    return b"".join([_rec(0x0296),
                     _rec(0x04E9, struct.pack("<I", 1)),
                     _rec(0x002F, struct.pack("<HHHHH", 0xFFFF, 0, 0, 0, 0) + b"\x00" * 6),
                     _rec(0x04EA),
                     _rec(0x0297)])


def _rels_xml(targets):
    ns = "http://schemas.openxmlformats.org/package/2006/relationships"
    t = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    rows = "".join(
        f'<Relationship Id="{rid}" Type="{t}/{typ}" Target="{tgt}"/>'
        for rid, typ, tgt in targets)
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="{ns}">{rows}</Relationships>'


_XLSB_CONTENT_TYPES = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
    '<Default Extension="bin" ContentType="application/vnd.ms-excel.sheet.binary.macroEnabled.main"/>'
    '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
    '</Types>')


def make_xlsb(path: str, rows: int) -> None:
    rng = random.Random(42)
    sheet_rows = []
    for r in range(rows):
        sheet_rows.append((r, [
            _cell(0x05, 0, 0, struct.pack("<d", float(r))),
            _cell(0x05, 1, 0, struct.pack("<d", rng.random() * 1000)),
            _cell(0x05, 2, 0, struct.pack("<d", float(r % 2))),
            _cell(0x06, 3, 0, _ws(f"row-{r:07d}")),
        ]))
    sbin = _xlsb_sheet(sheet_rows, 4)
    wb_rels = [("rId1", "worksheet", "worksheets/sheet1.bin"),
               ("rId2", "styles", "styles.bin")]

    def zinfo(name):
        zi = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
        zi.compress_type = zipfile.ZIP_DEFLATED
        return zi

    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(zinfo("[Content_Types].xml"), _XLSB_CONTENT_TYPES)
        z.writestr(zinfo("_rels/.rels"), _rels_xml([("rId1", "officeDocument", "xl/workbook.bin")]))
        z.writestr(zinfo("xl/workbook.bin"), _xlsb_workbook([("Bulk", "rId1", 0)]))
        z.writestr(zinfo("xl/_rels/workbook.bin.rels"), _rels_xml(wb_rels))
        z.writestr(zinfo("xl/worksheets/sheet1.bin"), sbin)
        z.writestr(zinfo("xl/styles.bin"), _xlsb_styles())


# ---------------------------------------------------------------- xls (BIFF8 in CFB)

def _biff(rid, payload):
    return struct.pack("<HH", rid, len(payload)) + payload


def _biff8_stream(rows: int) -> bytes:
    rng = random.Random(42)
    bof_globals = _biff(0x0809, struct.pack("<HHHHII", 0x0600, 0x0005, 0, 0, 0, 0x0600))
    datemode = _biff(0x0022, struct.pack("<H", 0))
    eof = _biff(0x000A, b"")
    name = b"Bulk"
    # BOUNDSHEET: lbPlyPos u32, visibility u8, type u8, short unicode name
    bs_payload_len = 4 + 1 + 1 + 1 + 1 + len(name)
    globals_len = len(bof_globals) + len(datemode) + (4 + bs_payload_len) + len(eof)
    boundsheet = _biff(0x0085, struct.pack("<IBB", globals_len, 0, 0)
                       + bytes([len(name), 0]) + name)
    sheet = [_biff(0x0809, struct.pack("<HHHHII", 0x0600, 0x0010, 0, 0, 0, 0x0600)),
             _biff(0x0200, struct.pack("<IIHHH", 0, rows, 0, 3, 0))]
    for r in range(rows):
        sheet.append(_biff(0x0203, struct.pack("<HHHd", r, 0, 0, float(r))))
        sheet.append(_biff(0x0203, struct.pack("<HHHd", r, 1, 0, rng.random() * 1000)))
        sheet.append(_biff(0x0203, struct.pack("<HHHd", r, 2, 0, float(r % 2))))
    sheet.append(eof)
    return bof_globals + datemode + boundsheet + eof + b"".join(sheet)


def _write_cfb(path: str, data: bytes) -> None:
    """Minimal v3 compound file: one 'Workbook' stream in the main FAT."""
    FREE, ENDCHAIN, FATSECT = 0xFFFFFFFF, 0xFFFFFFFE, 0xFFFFFFFD
    n_stream = (len(data) + 511) // 512
    nfat = 1
    while True:
        need = (nfat + 1 + n_stream + 127) // 128
        if need == nfat:
            break
        nfat = need
    dir_first = nfat
    stream_first = nfat + 1
    fat = [FATSECT] * nfat + [ENDCHAIN]
    for k in range(n_stream):
        fat.append(stream_first + k + 1 if k < n_stream - 1 else ENDCHAIN)
    fat += [FREE] * (nfat * 128 - len(fat))

    header = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1" + b"\x00" * 16
    header += struct.pack("<HHHHH", 0x003E, 0x0003, 0xFFFE, 9, 6)
    header += b"\x00" * 6
    header += struct.pack("<IIII", 0, nfat, dir_first, 0)
    header += struct.pack("<IIIII", 4096, ENDCHAIN, 0, ENDCHAIN, 0)
    difat = list(range(nfat)) + [FREE] * (109 - nfat)
    header += struct.pack("<109I", *difat)
    assert len(header) == 512

    def dirent(name, typ, start, size, child=FREE):
        nm = name.encode("utf-16-le") + b"\x00\x00" if name else b""
        e = nm.ljust(64, b"\x00")
        e += struct.pack("<HBB", len(nm), typ, 1)
        e += struct.pack("<III", FREE, FREE, child)
        e += b"\x00" * 16                      # clsid
        e += struct.pack("<I", 0)              # state
        e += b"\x00" * 16                      # timestamps
        e += struct.pack("<II", start, size)
        e += b"\x00" * 4
        return e

    directory = (dirent("Root Entry", 5, ENDCHAIN, 0, child=1)
                 + dirent("Workbook", 2, stream_first, len(data))
                 + dirent("", 0, 0, 0) + dirent("", 0, 0, 0))
    with open(path, "wb") as f:
        f.write(header)
        f.write(struct.pack(f"<{nfat * 128}I", *fat))
        f.write(directory.ljust(512, b"\x00"))
        f.write(data.ljust(n_stream * 512, b"\x00"))


def make_xls(path: str, rows: int) -> None:
    _write_cfb(path, _biff8_stream(rows))


# ---------------------------------------------------------------- matlab (MAT v5)
# The reader parses numeric payloads sequentially, so the random-access cost
# lives in the element walk: many small variables, not one big matrix.

def _mat_element(dtype, payload):
    r = len(payload) % 8
    padded = payload if r == 0 else payload + b"\x00" * (8 - r)
    return struct.pack("<ii", dtype, len(payload)) + padded


def make_matlab(path: str, nvars: int) -> None:
    miINT8, miINT32, miUINT32, miDOUBLE, miMATRIX = 1, 5, 6, 9, 14
    mxDOUBLE = 6
    rng = random.Random(42)
    text = b"MATLAB 5.0 MAT-file, driverless perf fixture"
    header = text + b" " * (116 - len(text)) + b"\x00" * 8 + struct.pack("<H", 0x0100) + b"IM"
    with open(path, "wb") as f:
        f.write(header)
        for v in range(nvars):
            flags = _mat_element(miUINT32, struct.pack("<II", mxDOUBLE, 0))
            dims = _mat_element(miINT32, struct.pack("<ii", 100, 2))
            name = _mat_element(miINT8, b"v%05d" % v)
            vals = [rng.random() * 1000 for _ in range(200)]
            pr = _mat_element(miDOUBLE, struct.pack("<200d", *vals))
            body = flags + dims + name + pr
            f.write(struct.pack("<ii", miMATRIX, len(body)) + body)


# ---------------------------------------------------------------- evtx

def make_evtx(path: str, records: int) -> None:
    spec = importlib.util.spec_from_file_location(
        "evtx_fixtures", os.path.join(REPO, "evtx", "test", "make_fixtures.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    chunks = []
    c = m.ChunkBuilder()
    rid = 1
    while rid <= records:
        when = m.BASE_TIME + datetime.timedelta(seconds=rid)
        c.add_record(rid, when, c.template_record(
            m.EVENT_GUID, m.event_tree(),
            m.event_subs(rid, when, "user%06d" % rid, 2)))
        rid += 1
        if c.pos > 0xE800:                      # chunk buffer is 0x10000
            chunks.append(c.finalize())
            c = m.ChunkBuilder()
    if c.first_id is not None:
        chunks.append(c.finalize())
    with open(path, "wb") as f:
        f.write(m.build_file(chunks, next_record_id=rid))


# ---------------------------------------------------------------- avro

def _avro_varint(n: int) -> bytes:
    u = ((n << 1) ^ (n >> 63)) & 0xFFFFFFFFFFFFFFFF   # zigzag
    out = bytearray()
    while True:
        b = u & 0x7F
        u >>= 7
        if u:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def make_avro(path: str, rows: int, block_records: int = 10000) -> None:
    schema = json.dumps({
        "type": "record", "name": "Row", "fields": [
            {"name": "id", "type": "long"},
            {"name": "name", "type": "string"},
            {"name": "value", "type": "double"},
            {"name": "flag", "type": "boolean"},
        ]})
    sync = b"powerquery-dperf"                        # 16 bytes
    rng = random.Random(42)

    def meta_string(b: bytes) -> bytes:
        return _avro_varint(len(b)) + b

    with open(path, "wb") as f:
        f.write(b"Obj\x01")
        f.write(_avro_varint(2))
        f.write(meta_string(b"avro.schema") + meta_string(schema.encode()))
        f.write(meta_string(b"avro.codec") + meta_string(b"null"))
        f.write(b"\x00")
        f.write(sync)
        i = 0
        while i < rows:
            n = min(block_records, rows - i)
            block = bytearray()
            for k in range(i, i + n):
                nm = f"row-{k:07d}".encode()
                block += _avro_varint(k)
                block += _avro_varint(len(nm)) + nm
                block += struct.pack("<d", rng.random() * 1000)
                block += b"\x01" if k % 2 else b"\x00"
            f.write(_avro_varint(n) + _avro_varint(len(block)) + bytes(block))
            f.write(sync)
            i += n


# ---------------------------------------------------------------- gpkg
# GeoPackage: sqlite container (fast on both sides via Sqlite3.Database);
# the per-row work under test is the GeoPackageBinary/WKB decode.

def make_gpkg(path: str, rows: int) -> None:
    if os.path.exists(path):
        os.remove(path)
    con = sqlite3.connect(path)
    cur = con.cursor()
    cur.execute("PRAGMA application_id = 1196444487")
    cur.execute("PRAGMA user_version = 10300")
    now = "2026-07-19T00:00:00.000Z"
    cur.execute("""CREATE TABLE gpkg_spatial_ref_sys (
        srs_name TEXT NOT NULL, srs_id INTEGER PRIMARY KEY,
        organization TEXT NOT NULL, organization_coordsys_id INTEGER NOT NULL,
        definition TEXT NOT NULL, description TEXT)""")
    cur.executemany("INSERT INTO gpkg_spatial_ref_sys VALUES (?,?,?,?,?,?)", [
        ("WGS 84 geodetic", 4326, "EPSG", 4326,
         'GEOGCS["WGS 84",DATUM["WGS_1984",SPHEROID["WGS 84",6378137,'
         '298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.0174532925199433]]',
         "longitude/latitude coordinates in decimal degrees"),
        ("undefined cartesian SRS", -1, "NONE", -1, "undefined", None),
        ("undefined geographic SRS", 0, "NONE", 0, "undefined", None),
    ])
    cur.execute("""CREATE TABLE gpkg_contents (
        table_name TEXT NOT NULL PRIMARY KEY, data_type TEXT NOT NULL,
        identifier TEXT UNIQUE, description TEXT DEFAULT '',
        last_change DATETIME NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
        min_x DOUBLE, min_y DOUBLE, max_x DOUBLE, max_y DOUBLE,
        srs_id INTEGER)""")
    cur.execute("""CREATE TABLE gpkg_geometry_columns (
        table_name TEXT NOT NULL, column_name TEXT NOT NULL,
        geometry_type_name TEXT NOT NULL, srs_id INTEGER NOT NULL,
        z TINYINT NOT NULL, m TINYINT NOT NULL,
        CONSTRAINT pk_geom_cols PRIMARY KEY (table_name, column_name))""")
    cur.execute("""CREATE TABLE points (
        fid INTEGER PRIMARY KEY, name TEXT, value REAL, geom BLOB)""")
    rng = random.Random(42)

    def gpb_point(x, y):
        head = b"GP" + bytes([0, 1]) + struct.pack("<i", 4326)
        wkb = struct.pack("<BI", 1, 1) + struct.pack("<dd", x, y)
        return head + wkb

    cur.executemany(
        "INSERT INTO points VALUES (?,?,?,?)",
        ((i, f"pt-{i:07d}", rng.random() * 1000,
          gpb_point(rng.random() * 360 - 180, rng.random() * 180 - 90))
         for i in range(rows)))
    cur.execute("INSERT INTO gpkg_contents VALUES (?,?,?,?,?,?,?,?,?,?)",
                ("points", "features", "points", "bulk points", now,
                 -180.0, -90.0, 180.0, 90.0, 4326))
    cur.execute("INSERT INTO gpkg_geometry_columns VALUES (?,?,?,?,?,?)",
                ("points", "geom", "POINT", 4326, 0, 0))
    con.commit()
    con.close()


# ---------------------------------------------------------------- mbtiles
# MBTiles: a SQLite container of map tiles. The per-tile work under test is
# Mbtiles.Document's gzip auto-decompression of vector (pbf) tiles, so every
# tile_data blob is a gzip-compressed synthetic MVT payload. Plain `tiles`
# table layout (MBTiles 1.x); the driverless reader returns decompressed
# blobs, which the native side (sqlite3 + gzip) reproduces exactly.

def make_mbtiles(path: str, tiles: int) -> None:
    if os.path.exists(path):
        os.remove(path)
    con = sqlite3.connect(path)
    cur = con.cursor()
    cur.execute("CREATE TABLE metadata (name TEXT, value TEXT)")
    cur.executemany("INSERT INTO metadata VALUES (?,?)", [
        ("name", "perf-bulk"),
        ("format", "pbf"),
        ("minzoom", "10"),
        ("maxzoom", "10"),
        ("bounds", "-180.0,-85.0,180.0,85.0"),
        ("type", "overlay"),
        ("version", "1.0"),
    ])
    cur.execute("""CREATE TABLE tiles (
        zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER,
        tile_data BLOB,
        PRIMARY KEY (zoom_level, tile_column, tile_row))""")
    rng = random.Random(42)
    z, width = 10, 1024                     # tile_column/tile_row both < 2^10

    def rows():
        for i in range(tiles):
            # synthetic MVT-ish payload: a coordinate tag plus a fixed run of
            # pseudo-random bytes, gzip-compressed as the spec requires.
            x, y = i // width, i % width
            payload = (("t-%d-%d-%d-" % (z, x, y)).encode()
                       + bytes(rng.randrange(256) for _ in range(400)))
            yield (z, x, y, gzip.compress(payload, 6))

    cur.executemany("INSERT INTO tiles VALUES (?,?,?,?)", rows())
    con.commit()
    con.close()


# ---------------------------------------------------------------- main

def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(HERE, "out"))
    ap.add_argument("--sqlite-rows", type=int, default=1_000_000)
    ap.add_argument("--dbf-rows", type=int, default=20_000)
    ap.add_argument("--stata-rows", type=int, default=50_000)
    ap.add_argument("--spss-rows", type=int, default=40_000)
    ap.add_argument("--xlsb-rows", type=int, default=10_000)
    ap.add_argument("--xls-rows", type=int, default=8_000)
    ap.add_argument("--matlab-vars", type=int, default=600)
    ap.add_argument("--evtx-records", type=int, default=1_500)
    ap.add_argument("--avro-rows", type=int, default=150_000)
    ap.add_argument("--gpkg-rows", type=int, default=15_000)
    ap.add_argument("--mbtiles-tiles", type=int, default=10_000)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    jobs = [
        ("bulk.db", make_sqlite, args.sqlite_rows),
        ("bulk.dbf", make_dbf, args.dbf_rows),
        ("bulk.dta", make_stata, args.stata_rows),
        ("bulk.sav", make_spss, args.spss_rows),
        ("bulk.xlsb", make_xlsb, args.xlsb_rows),
        ("bulk.xls", make_xls, args.xls_rows),
        ("bulk.mat", make_matlab, args.matlab_vars),
        ("bulk.evtx", make_evtx, args.evtx_records),
        ("bulk.avro", make_avro, args.avro_rows),
        ("bulk.gpkg", make_gpkg, args.gpkg_rows),
        ("bulk.mbtiles", make_mbtiles, args.mbtiles_tiles),
    ]
    for name, fn, n in jobs:
        p = os.path.join(args.out, name)
        fn(p, n)
        print(f"{name}: {os.path.getsize(p):,} bytes ({n:,})")


if __name__ == "__main__":
    main()
