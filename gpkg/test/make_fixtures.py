#!/usr/bin/env python3
"""Generate the GeoPackage fixture for Gpkg.Database.pq.

Everything is synthetic and hand-built with the Python stdlib (sqlite3 +
struct): no GDAL, no fiona. The GeoPackageBinary blobs are constructed byte by
byte so the fixture exercises exactly the cases the reader must handle
(envelope indicators, both byte orders, empty and null geometries, Z/M/ZM
dimensions) rather than whatever one writer happens to emit.

Run: python3 make_fixtures.py  (writes basic.gpkg next to this script)
"""

import os
import sqlite3
import struct

HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- WKB writer

# geometry type codes; Z = +1000, M = +2000, ZM = +3000
POINT, LINESTRING, POLYGON = 1, 2, 3
MULTIPOINT, MULTILINESTRING, MULTIPOLYGON, COLLECTION = 4, 5, 6, 7


def _end(little):
    return "<" if little else ">"


def wkb_header(code, little=True):
    return struct.pack(_end(little) + "BI", 1 if little else 0, code)


def wkb_coords(pts, little=True):
    n = len(pts[0])
    fmt = _end(little) + "d" * n
    return b"".join(struct.pack(fmt, *p) for p in pts)


def wkb_point(pt, dim=0, little=True):
    return wkb_header(POINT + dim, little) + wkb_coords([pt], little)


def wkb_linestring(pts, dim=0, little=True):
    return (wkb_header(LINESTRING + dim, little)
            + struct.pack(_end(little) + "I", len(pts))
            + wkb_coords(pts, little))


def wkb_polygon(rings, dim=0, little=True):
    body = struct.pack(_end(little) + "I", len(rings))
    for ring in rings:
        body += struct.pack(_end(little) + "I", len(ring)) + wkb_coords(ring, little)
    return wkb_header(POLYGON + dim, little) + body


def wkb_multi(code, parts, little=True):
    return (wkb_header(code, little)
            + struct.pack(_end(little) + "I", len(parts))
            + b"".join(parts))


# ------------------------------------------------------- GeoPackageBinary

def gpb(wkb, srs_id=4326, envelope=None, env_indicator=0, little=True,
        empty=False, extended=False):
    """Wrap a WKB body in a GeoPackageBinary header.

    envelope: flat list of doubles matching env_indicator
      (0: none, 1: [minx,maxx,miny,maxy], 2: +minz,maxz, 3: +minm,maxm, 4: both)
    """
    flags = (1 if little else 0) | (env_indicator << 1)
    if empty:
        flags |= 0x10
    if extended:
        flags |= 0x20
    head = b"GP" + bytes([0, flags]) + struct.pack(_end(little) + "i", srs_id)
    if envelope:
        head += struct.pack(_end(little) + "d" * len(envelope), *envelope)
    return head + wkb


NAN = float("nan")

# ---------------------------------------------------------------- fixtures

PNG_1PX = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000d4944415478da63f8cfc0f01f0005050202b8bdbdc70000000049454e44"
    "ae426082"
)


def make_basic(path):
    if os.path.exists(path):
        os.remove(path)
    con = sqlite3.connect(path)
    cur = con.cursor()
    cur.execute("PRAGMA application_id = 1196444487")   # 0x47504B47 = 'GPKG'
    cur.execute("PRAGMA user_version = 10300")          # GeoPackage 1.3.0

    NOW = "2026-07-17T00:00:00.000Z"

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

    # ---- points: POINT column, envelope/byte-order/empty/null variants
    cur.execute("""CREATE TABLE points (
        fid INTEGER PRIMARY KEY, name TEXT, rating REAL, geom BLOB)""")
    pts = [
        (1, "alpha", 4.5,
         gpb(wkb_point((30.0, 10.0)))),
        (2, "bravo", -0.25,
         gpb(wkb_point((-101.5, 45.25)), envelope=[-101.5, -101.5, 45.25, 45.25],
             env_indicator=1)),
        (3, "charlie-BE", 2.0,
         gpb(wkb_point((2.5, 3.5), little=False),
             envelope=[2.5, 2.5, 3.5, 3.5], env_indicator=1, little=False)),
        (4, "empty", None,
         gpb(wkb_point((NAN, NAN)), empty=True)),
        (5, "nogeom", 1.5, None),
    ]
    cur.executemany("INSERT INTO points VALUES (?,?,?,?)", pts)
    cur.execute("INSERT INTO gpkg_contents VALUES (?,?,?,?,?,?,?,?,?,?)",
                ("points", "features", "points", "point variants", NOW,
                 -101.5, 3.5, 30.0, 45.25, 4326))
    cur.execute("INSERT INTO gpkg_geometry_columns VALUES (?,?,?,?,?,?)",
                ("points", "geom", "POINT", 4326, 0, 0))

    # ---- shapes: GEOMETRY column named "shape", one of each WKB type
    cur.execute("""CREATE TABLE shapes (
        fid INTEGER PRIMARY KEY, kind TEXT, shape BLOB)""")
    ls = wkb_linestring([(30.0, 10.0), (10.0, 30.0), (40.0, 40.0)])
    poly = wkb_polygon([
        [(35.0, 10.0), (45.0, 45.0), (15.0, 40.0), (10.0, 20.0), (35.0, 10.0)],
        [(20.0, 30.0), (35.0, 35.0), (30.0, 20.0), (20.0, 30.0)],
    ])
    mpt = wkb_multi(MULTIPOINT, [wkb_point((10.0, 40.0)), wkb_point((40.0, 30.0)),
                                 wkb_point((20.0, 20.0)), wkb_point((30.0, 10.0))])
    mls = wkb_multi(MULTILINESTRING, [
        wkb_linestring([(10.0, 10.0), (20.0, 20.0), (10.0, 40.0)]),
        wkb_linestring([(40.0, 40.0), (30.0, 30.0), (40.0, 20.0), (30.0, 10.0)]),
    ])
    mpoly = wkb_multi(MULTIPOLYGON, [
        wkb_polygon([[(30.0, 20.0), (45.0, 40.0), (10.0, 40.0), (30.0, 20.0)]]),
        wkb_polygon([[(15.0, 5.0), (40.0, 10.0), (10.0, 20.0), (5.0, 10.0),
                      (15.0, 5.0)]]),
    ])
    coll = wkb_multi(COLLECTION, [wkb_point((40.0, 10.0)),
                                  wkb_linestring([(10.0, 10.0), (20.0, 20.0),
                                                  (10.0, 40.0)])])
    empty_mpoly = wkb_multi(MULTIPOLYGON, [])
    zls = wkb_linestring([(1.0, 2.0, 3.0), (4.0, 5.0, 6.0)], dim=1000)
    shapes = [
        (1, "linestring", gpb(ls, envelope=[10.0, 40.0, 10.0, 40.0], env_indicator=1)),
        (2, "polygon", gpb(poly)),
        (3, "multipoint", gpb(mpt)),
        (4, "multilinestring", gpb(mls)),
        (5, "multipolygon", gpb(mpoly)),
        (6, "collection", gpb(coll)),
        (7, "emptymulti", gpb(empty_mpoly, empty=True)),
        (8, "linestring-z", gpb(zls, envelope=[1.0, 4.0, 2.0, 5.0, 3.0, 6.0],
                                env_indicator=2)),
    ]
    cur.executemany("INSERT INTO shapes VALUES (?,?,?)", shapes)
    cur.execute("INSERT INTO gpkg_contents VALUES (?,?,?,?,?,?,?,?,?,?)",
                ("shapes", "features", "shapes", "one of each geometry type", NOW,
                 5.0, 5.0, 45.0, 45.0, 4326))
    cur.execute("INSERT INTO gpkg_geometry_columns VALUES (?,?,?,?,?,?)",
                ("shapes", "shape", "GEOMETRY", 4326, 2, 2))

    # ---- zm: Z / M / ZM points
    cur.execute("""CREATE TABLE zm (fid INTEGER PRIMARY KEY, tag TEXT, geom BLOB)""")
    zm = [
        (1, "z", gpb(wkb_point((1.0, 2.0, 3.0), dim=1000))),
        (2, "m", gpb(wkb_point((1.0, 2.0, 4.0), dim=2000))),
        (3, "zm", gpb(wkb_point((1.0, 2.0, 3.0, 4.0), dim=3000),
                      envelope=[1.0, 1.0, 2.0, 2.0, 3.0, 3.0, 4.0, 4.0],
                      env_indicator=4)),
    ]
    cur.executemany("INSERT INTO zm VALUES (?,?,?)", zm)
    cur.execute("INSERT INTO gpkg_contents VALUES (?,?,?,?,?,?,?,?,?,?)",
                ("zm", "features", "zm", "Z, M and ZM points", NOW,
                 1.0, 2.0, 1.0, 2.0, 4326))
    cur.execute("INSERT INTO gpkg_geometry_columns VALUES (?,?,?,?,?,?)",
                ("zm", "geom", "GEOMETRY", 4326, 2, 2))

    # ---- attrs: attributes data_type, no geometry
    cur.execute("""CREATE TABLE attrs (
        id INTEGER PRIMARY KEY, label TEXT, val REAL, flag INTEGER, payload BLOB)""")
    cur.executemany("INSERT INTO attrs VALUES (?,?,?,?,?)", [
        (1, "plain", 1.5, 1, b"\x01\x02\x03"),
        (2, "unicode éș中", -7.0, 0, None),
        (3, None, None, None, None),
    ])
    cur.execute("INSERT INTO gpkg_contents VALUES (?,?,?,?,?,?,?,?,?,?)",
                ("attrs", "attributes", "attrs", "non-spatial attributes", NOW,
                 None, None, None, None, None))

    # ---- tiles_demo: tile pyramid with two 1x1 PNGs
    cur.execute("""CREATE TABLE gpkg_tile_matrix_set (
        table_name TEXT NOT NULL PRIMARY KEY, srs_id INTEGER NOT NULL,
        min_x DOUBLE NOT NULL, min_y DOUBLE NOT NULL,
        max_x DOUBLE NOT NULL, max_y DOUBLE NOT NULL)""")
    cur.execute("""CREATE TABLE gpkg_tile_matrix (
        table_name TEXT NOT NULL, zoom_level INTEGER NOT NULL,
        matrix_width INTEGER NOT NULL, matrix_height INTEGER NOT NULL,
        tile_width INTEGER NOT NULL, tile_height INTEGER NOT NULL,
        pixel_x_size DOUBLE NOT NULL, pixel_y_size DOUBLE NOT NULL,
        CONSTRAINT pk_ttm PRIMARY KEY (table_name, zoom_level))""")
    cur.execute("""CREATE TABLE tiles_demo (
        id INTEGER PRIMARY KEY, zoom_level INTEGER NOT NULL,
        tile_column INTEGER NOT NULL, tile_row INTEGER NOT NULL,
        tile_data BLOB NOT NULL,
        UNIQUE (zoom_level, tile_column, tile_row))""")
    cur.execute("INSERT INTO gpkg_tile_matrix_set VALUES (?,?,?,?,?,?)",
                ("tiles_demo", 4326, -180.0, -90.0, 180.0, 90.0))
    cur.executemany("INSERT INTO gpkg_tile_matrix VALUES (?,?,?,?,?,?,?,?)", [
        ("tiles_demo", 0, 2, 1, 256, 256, 0.703125, 0.703125),
        ("tiles_demo", 1, 4, 2, 256, 256, 0.3515625, 0.3515625),
    ])
    cur.executemany("INSERT INTO tiles_demo VALUES (?,?,?,?,?)", [
        (1, 0, 0, 0, PNG_1PX),
        (2, 0, 1, 0, PNG_1PX),
        (3, 1, 2, 1, PNG_1PX),
    ])
    cur.execute("INSERT INTO gpkg_contents VALUES (?,?,?,?,?,?,?,?,?,?)",
                ("tiles_demo", "tiles", "tiles_demo", "1x1 png pyramid", NOW,
                 -180.0, -90.0, 180.0, 90.0, 4326))

    # ---- rtree spatial-index noise: must NOT appear in the nav table
    cur.execute("""CREATE TABLE gpkg_extensions (
        table_name TEXT, column_name TEXT, extension_name TEXT NOT NULL,
        definition TEXT NOT NULL, scope TEXT NOT NULL)""")
    cur.execute("INSERT INTO gpkg_extensions VALUES (?,?,?,?,?)",
                ("points", "geom", "gpkg_rtree_index",
                 "http://www.geopackage.org/spec/#extension_rtree", "write-only"))
    cur.execute("""CREATE VIRTUAL TABLE rtree_points_geom USING rtree(
        id, minx, maxx, miny, maxy)""")
    cur.executemany("INSERT INTO rtree_points_geom VALUES (?,?,?,?,?)", [
        (1, 30.0, 30.0, 10.0, 10.0),
        (2, -101.5, -101.5, 45.25, 45.25),
        (3, 2.5, 2.5, 3.5, 3.5),
    ])

    con.commit()
    con.close()
    print("wrote", path, os.path.getsize(path), "bytes")


if __name__ == "__main__":
    make_basic(os.path.join(HERE, "basic.gpkg"))
