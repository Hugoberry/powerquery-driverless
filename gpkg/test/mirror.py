#!/usr/bin/env python3
"""Python mirror of the GeoPackageBinary + WKB parse logic destined for
Gpkg.Database.pq.

This is the semantic reference for the M translation: same decisions, same
offsets, same recursion shape, same WKT formatting. Validated by
check_mirror.py against shapely (independent WKB reader) and hand-written
expected literals before the logic was translated to M 1:1.

Deliberate M parallels:
- no struct format strings for multi-field reads; every read is
  (offset, size) -> value, like Binary.Range slices
- WKT numbers are formatted the way .NET round-trip ("R", en-US) prints
  doubles: integral values without a decimal point
- unsupported cases return an error string starting with "!", which the M
  turns into null (permissive) or an error (Strict)
"""

import math
import struct


def u8(b, o):
    return b[o]


def u32(b, o, little):
    return int.from_bytes(b[o:o + 4], "little" if little else "big")


def i32(b, o, little):
    return int.from_bytes(b[o:o + 4], "little" if little else "big", signed=True)


def f64(b, o, little):
    return struct.unpack(("<" if little else ">") + "d", b[o:o + 8])[0]


def fmt(v):
    """Format a coordinate as the M reader will (.NET "R", en-US)."""
    if math.isnan(v):
        return "NaN"
    if v == int(v) and abs(v) < 1e15:
        return str(int(v))
    return repr(v)


TYPE_NAMES = {1: "POINT", 2: "LINESTRING", 3: "POLYGON", 4: "MULTIPOINT",
              5: "MULTILINESTRING", 6: "MULTIPOLYGON", 7: "GEOMETRYCOLLECTION"}
DIM_SUFFIX = {0: "", 1: " Z", 2: " M", 3: " ZM"}
ENVELOPE_DOUBLES = {0: 0, 1: 4, 2: 6, 3: 6, 4: 8}


def wkb_geometry(b, o):
    """Parse one WKB geometry at offset o.

    Returns (wkt_text, next_offset). Mirrors the M function WkbGeometry.
    """
    little = u8(b, o) == 1
    code = u32(b, o + 1, little)
    dim = code // 1000
    base = code % 1000
    if base not in TYPE_NAMES or dim > 3:
        return ("!unsupported WKB geometry type code " + str(code), o + 5)
    name = TYPE_NAMES[base] + DIM_SUFFIX[dim]
    ncoord = 2 + (1 if dim in (1, 2) else 2 if dim == 3 else 0)
    o = o + 5

    def coords(o, n):
        pts = []
        for _ in range(n):
            vs = [f64(b, o + 8 * i, little) for i in range(ncoord)]
            pts.append(" ".join(fmt(v) for v in vs))
            o += 8 * ncoord
        return pts, o

    if base == 1:                                   # point
        pts, o = coords(o, 1)
        if all(math.isnan(f64(b, o - 8 * ncoord + 8 * i, little))
               for i in range(ncoord)):
            return (name + " EMPTY", o)
        return (name + " (" + pts[0] + ")", o)
    if base == 2:                                   # linestring
        n = u32(b, o, little)
        if n == 0:
            return (name + " EMPTY", o + 4)
        pts, o = coords(o + 4, n)
        return (name + " (" + ", ".join(pts) + ")", o)
    if base == 3:                                   # polygon
        n = u32(b, o, little)
        if n == 0:
            return (name + " EMPTY", o + 4)
        o += 4
        rings = []
        for _ in range(n):
            m = u32(b, o, little)
            pts, o = coords(o + 4, m)
            rings.append("(" + ", ".join(pts) + ")")
        return (name + " (" + ", ".join(rings) + ")", o)
    # multi* / collection: n child geometries, each with its own header
    n = u32(b, o, little)
    if n == 0:
        return (name + " EMPTY", o + 4)
    o += 4
    parts = []
    for _ in range(n):
        wkt, o = wkb_geometry(b, o)
        if wkt.startswith("!"):
            return (wkt, o)
        if base == 4:                               # multipoint: strip "POINT "
            inner = wkt[wkt.index("("):] if "(" in wkt else "EMPTY"
            parts.append(inner)
        elif base in (5, 6):                        # strip child type name
            inner = wkt[wkt.index("("):] if "(" in wkt else "EMPTY"
            parts.append(inner)
        else:                                       # collection keeps full WKT
            parts.append(wkt)
    return (name + " (" + ", ".join(parts) + ")", o)


def parse_gpb(blob):
    """Parse a GeoPackageBinary blob.

    Returns dict [Srsid, Wkt, Empty] or an error string starting with "!".
    Mirrors the M function GpbToWkt.
    """
    if blob is None:
        return None
    if len(blob) < 8 or blob[0:2] != b"GP":
        return "!not a GeoPackageBinary blob (bad magic)"
    version = u8(blob, 2)
    if version != 0:
        return "!unsupported GeoPackageBinary version " + str(version)
    flags = u8(blob, 3)
    little = (flags & 1) == 1
    env_ind = (flags >> 1) & 7
    empty = (flags & 0x10) != 0
    extended = (flags & 0x20) != 0
    if env_ind > 4:
        return "!invalid envelope contents indicator " + str(env_ind)
    srs_id = i32(blob, 4, little)
    wkb_off = 8 + 8 * ENVELOPE_DOUBLES[env_ind]
    if extended:
        return "!extended GeoPackageBinary (extension-defined payload)"
    wkt, _ = wkb_geometry(blob, wkb_off)
    if wkt.startswith("!"):
        return wkt
    if empty and not wkt.endswith(" EMPTY"):
        # header says empty but WKB carries coordinates: trust the flag
        head = wkt.split(" (")[0]
        wkt = head + " EMPTY"
    return {"Srsid": srs_id, "Wkt": wkt, "Empty": empty or wkt.endswith(" EMPTY")}
