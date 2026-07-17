#!/usr/bin/env python3
"""Generate the MBTiles fixtures for Mbtiles.Document.pq.

Everything is synthetic and stdlib-only (sqlite3 + zlib + struct). Three
fixtures cover the three layouts in the wild:

  raster.mbtiles  - plain `tiles` table, per-color 1x1 PNGs (MBTiles 1.3)
  vector.mbtiles  - format=pbf, tile_data gzip-compressed (as the spec requires)
  deduped.mbtiles - tippecanoe layout: `map` + `images` tables and `tiles` as a
                    view; two map rows share one image (the dedup case)

Run: python3 make_fixtures.py
"""

import gzip
import os
import sqlite3
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))


def png_1px(rgb):
    """A valid 1x1 RGB PNG in the given color, built from scratch."""
    def chunk(tag, data):
        raw = tag + data
        return struct.pack(">I", len(data)) + raw + struct.pack(">I", zlib.crc32(raw))
    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    idat = zlib.compress(b"\x00" + bytes(rgb), 9)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", idat) + chunk(b"IEND", b""))


RED, GREEN, BLUE = png_1px((255, 0, 0)), png_1px((0, 255, 0)), png_1px((0, 0, 255))


def fresh(path):
    if os.path.exists(path):
        os.remove(path)
    return sqlite3.connect(path)


def put_metadata(cur, rows):
    cur.execute("CREATE TABLE metadata (name TEXT, value TEXT)")
    cur.executemany("INSERT INTO metadata VALUES (?,?)", rows)


def make_raster(path):
    con = fresh(path)
    cur = con.cursor()
    put_metadata(cur, [
        ("name", "raster-demo"),
        ("format", "png"),
        ("bounds", "-180.0,-85,180,85"),
        ("center", "0,0,0"),
        ("minzoom", "0"),
        ("maxzoom", "1"),
        ("type", "baselayer"),
        ("version", "1.1"),
    ])
    cur.execute("""CREATE TABLE tiles (
        zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)""")
    cur.execute("""CREATE UNIQUE INDEX tile_index
        ON tiles (zoom_level, tile_column, tile_row)""")
    cur.executemany("INSERT INTO tiles VALUES (?,?,?,?)", [
        (0, 0, 0, RED),
        (1, 0, 1, GREEN),   # TMS row 1 at z1 = XYZ row 0
        (1, 1, 0, BLUE),    # TMS row 0 at z1 = XYZ row 1
    ])
    con.commit()
    con.close()
    print("wrote", path, os.path.getsize(path), "bytes")


def make_vector(path):
    con = fresh(path)
    cur = con.cursor()
    put_metadata(cur, [
        ("name", "vector-demo"),
        ("format", "pbf"),
        ("minzoom", "0"),
        ("maxzoom", "1"),
        ("json", '{"vector_layers":[{"id":"demo","fields":{}}]}'),
    ])
    cur.execute("""CREATE TABLE tiles (
        zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)""")
    # not real MVT protobuf, but distinct recognisable payloads: the reader
    # treats tile_data as opaque bytes and only handles the gzip wrapper
    cur.executemany("INSERT INTO tiles VALUES (?,?,?,?)", [
        (0, 0, 0, gzip.compress(b"fake-mvt-payload-A")),
        (1, 0, 0, b"raw-not-gzipped"),   # must pass through untouched in auto mode
    ])
    con.commit()
    con.close()
    print("wrote", path, os.path.getsize(path), "bytes")


def make_deduped(path):
    con = fresh(path)
    cur = con.cursor()
    put_metadata(cur, [
        ("name", "deduped-demo"),
        ("format", "png"),
        ("minzoom", "1"),
        ("maxzoom", "1"),
    ])
    cur.execute("""CREATE TABLE map (
        zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_id TEXT)""")
    cur.execute("CREATE TABLE images (tile_id TEXT, tile_data BLOB)")
    cur.execute("""CREATE VIEW tiles AS
        SELECT map.zoom_level AS zoom_level, map.tile_column AS tile_column,
               map.tile_row AS tile_row, images.tile_data AS tile_data
        FROM map JOIN images ON images.tile_id = map.tile_id""")
    cur.executemany("INSERT INTO images VALUES (?,?)", [
        ("sea", BLUE),
        ("land", GREEN),
    ])
    cur.executemany("INSERT INTO map VALUES (?,?,?,?)", [
        (1, 0, 0, "sea"),
        (1, 0, 1, "sea"),    # same image as (1,0,0): the dedup case
        (1, 1, 1, "land"),
    ])
    con.commit()
    con.close()
    print("wrote", path, os.path.getsize(path), "bytes")


if __name__ == "__main__":
    make_raster(os.path.join(HERE, "raster.mbtiles"))
    make_vector(os.path.join(HERE, "vector.mbtiles"))
    make_deduped(os.path.join(HERE, "deduped.mbtiles"))
