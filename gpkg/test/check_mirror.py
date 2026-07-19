#!/usr/bin/env python3
"""Validate mirror.py against basic.gpkg, two ways:

1. cell-by-cell against shapely (an independent WKB reader wrapping GEOS),
2. against hand-written expected WKT literals, so a shared misreading of the
   spec by mirror and shapely alike would still be caught.

Run: venv/bin/python check_mirror.py
"""

import sqlite3
import sys

import shapely
from mirror import ENVELOPE_DOUBLES, parse_gpb

DB = __file__.rsplit("/", 1)[0] + "/basic.gpkg"

EXPECTED = {
    ("points", 1): (4326, "POINT (30 10)"),
    ("points", 2): (4326, "POINT (-101.5 45.25)"),
    ("points", 3): (4326, "POINT (2.5 3.5)"),
    ("points", 4): (4326, "POINT EMPTY"),
    ("points", 5): None,
    ("shapes", 1): (4326, "LINESTRING (30 10, 10 30, 40 40)"),
    ("shapes", 2): (4326, "POLYGON ((35 10, 45 45, 15 40, 10 20, 35 10), "
                          "(20 30, 35 35, 30 20, 20 30))"),
    ("shapes", 3): (4326, "MULTIPOINT ((10 40), (40 30), (20 20), (30 10))"),
    ("shapes", 4): (4326, "MULTILINESTRING ((10 10, 20 20, 10 40), "
                          "(40 40, 30 30, 40 20, 30 10))"),
    ("shapes", 5): (4326, "MULTIPOLYGON (((30 20, 45 40, 10 40, 30 20)), "
                          "((15 5, 40 10, 10 20, 5 10, 15 5)))"),
    ("shapes", 6): (4326, "GEOMETRYCOLLECTION (POINT (40 10), "
                          "LINESTRING (10 10, 20 20, 10 40))"),
    ("shapes", 7): (4326, "MULTIPOLYGON EMPTY"),
    ("shapes", 8): (4326, "LINESTRING Z (1 2 3, 4 5 6)"),
    ("zm", 1): (4326, "POINT Z (1 2 3)"),
    ("zm", 2): (4326, "POINT M (1 2 4)"),
    ("zm", 3): (4326, "POINT ZM (1 2 3 4)"),
}

GEOM_COL = {"points": "geom", "shapes": "shape", "zm": "geom"}


def wkb_bytes(blob):
    """Strip the GeoPackageBinary header, returning the raw WKB body."""
    flags = blob[3]
    return blob[8 + 8 * ENVELOPE_DOUBLES[(flags >> 1) & 7]:]


def shapely_wkt(blob):
    return str(shapely.from_wkb(wkb_bytes(blob)))


def norm_multipoint(wkt):
    """Shapely may print MULTIPOINT without per-point parens; normalise ours
    down to that form for the comparison only."""
    if not wkt.startswith("MULTIPOINT ("):
        return wkt
    inner = wkt[len("MULTIPOINT ("):-1]
    inner = inner.replace("(", "").replace(")", "")
    return "MULTIPOINT (" + inner + ")"


def main():
    con = sqlite3.connect(DB)
    failures = 0
    for (table, fid), want in EXPECTED.items():
        blob = con.execute(
            f"SELECT {GEOM_COL[table]} FROM {table} WHERE fid = ?",
            (fid,)).fetchone()[0]
        got = parse_gpb(blob)
        label = f"{table}/{fid}"

        if want is None:
            if got is not None:
                print(f"FAIL {label}: expected null geometry, got {got}")
                failures += 1
            continue
        if isinstance(got, str):                       # "!..." error from mirror
            print(f"FAIL {label}: mirror error: {got}")
            failures += 1
            continue

        want_srs, want_wkt = want
        if got["Srsid"] != want_srs:
            print(f"FAIL {label}: srs {got['Srsid']} != {want_srs}")
            failures += 1
        if got["Wkt"] != want_wkt:
            print(f"FAIL {label}: literal mismatch\n  mirror : {got['Wkt']}"
                  f"\n  expect : {want_wkt}")
            failures += 1

        sh = shapely_wkt(blob)
        mine = got["Wkt"]
        if norm_multipoint(mine) != norm_multipoint(sh):
            print(f"FAIL {label}: shapely disagrees\n  mirror : {mine}"
                  f"\n  shapely: {sh}")
            failures += 1

    if failures == 0:
        print(f"OK: all {len(EXPECTED)} geometries verified")
    else:
        print(f"{failures} FAILURES")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
