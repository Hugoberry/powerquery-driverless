# GeoPackage reader

Reads OGC GeoPackage files (`.gpkg`) in pure Power Query M. No GDAL, no
spatial ODBC driver, nothing to install.

GeoPackage is the format OGC standardised to replace shapefile, and QGIS,
ArcGIS and every modern GIS tool export it by default. Power BI has no native
support at all: the usual advice is to convert the file with GDAL or load it
into a spatial database first. A GeoPackage is a SQLite database with a
specified schema, so this reader parses the file directly and hands Power BI
what its map visuals actually consume: attribute tables with geometry as
well-known text (WKT).

## Usage

This reader depends on the SQLite core next to it: paste
[`../sqlite3/Sqlite3.Database.pq`](../sqlite3/Sqlite3.Database.pq) into a
blank query named `Sqlite3.Database`, then paste
[`Gpkg.Database.pq`](Gpkg.Database.pq) into a second blank query named
`Gpkg.Database`. Then:

```m
let
    Source = File.Contents("C:\data\survey.gpkg"),
    Gp     = Gpkg.Database(Source),          // navigation table, one row per layer
    Layer  = Gp{[Name = "parcels"]}[Data]    // attributes + geometry as WKT
in
    Layer
```

The navigation table has one entry per `gpkg_contents` row: feature layers,
attribute (non-spatial) tables and tile pyramids, with a `DataType` column
telling them apart. Feature layers come back with their geometry column
converted to WKT text; icon-map and Azure-map visuals consume that directly.

### Options

Second argument, optional record, all keys optional:

| Key | Default | Effect |
|---|---|---|
| `GeometryFormat` | `"WKT"` | `"WKT"` converts geometry to well-known text; `"WKB"` returns raw ISO well-known binary with the GeoPackage header stripped; `"GeoPackageBinary"` returns the stored blob untouched |
| `IncludeSystemTables` | `false` | Also list the `gpkg_*` catalog tables (contents, geometry columns, spatial reference systems, tile matrices, extensions) |
| `MaxRows` | all | Return at most N rows per table |
| `Strict` | `false` | Error on tolerated malformations (undecodable geometry blobs return `null` by default) |

The navigation table carries `Gpkg.ApplicationId` and `Gpkg.UserVersion` as
metadata; each feature table carries `Gpkg.SrsId`, `Gpkg.DataType` and
`Gpkg.Description` from its `gpkg_contents` entry.

## Supported

- Features, attributes and tiles data types from `gpkg_contents`; unknown
  data types (coverage extensions and the like) come through as plain tables.
- All ISO WKB geometry types: Point, LineString, Polygon, MultiPoint,
  MultiLineString, MultiPolygon, GeometryCollection, each in XY, Z, M and ZM
  dimensions.
- Both byte orders, per GeoPackageBinary header and per WKB geometry
  (the WKB spec allows them to differ within one blob).
- All envelope indicators (none, XY, XYZ, XYM, XYZM), the empty-geometry
  flag, and NULL geometry cells.
- Tile pyramids: `zoom_level` / `tile_column` / `tile_row` plus the PNG or
  JPEG blob per tile, exposed as binary.
- On the SQLite side (delegated to `Sqlite3.Database`): multi-level b-trees,
  overflow pages, UTF-8/16 encodings, rowid aliasing of
  `INTEGER PRIMARY KEY` columns.

## Limitations

- **Extended GeoPackageBinary** geometries (flag bit 5, extension-defined
  payloads such as compressed geometries) are not decoded: the cell is `null`
  by default and a clear error under `Strict`.
- **Features registered as SQL views** produce a clear error for that entry;
  there is no SQL engine here to evaluate a view.
- **rtree spatial-index internals** (`rtree_%` shadow tables) are
  deliberately hidden; they are derivable bookkeeping, not data.
- **No reprojection.** Geometry comes back in the file's own coordinate
  reference system; the SRS id is in the table metadata. Power BI map visuals
  want WGS 84 (EPSG:4326), so reproject upstream if the file is in a
  projected CRS.
- **Memory.** The whole file is buffered; peak memory is a multiple of file
  size. Fine for the megabyte-to-hundreds-of-megabytes files GeoPackage is
  typically used for.
- **Precision.** Integer cells decode exactly across the full signed 64-bit
  range (inherited from `Sqlite3.Database`). M numbers are IEEE doubles, so
  arithmetic on values beyond 2^53 afterwards can still coerce to double.

### Why two queries

Every other reader in this repository is a single self-contained paste. This
one (and the MBTiles reader) is the deliberate exception: a GeoPackage is a
SQLite database, the SQLite b-tree parser is by far the largest piece of code
involved, and duplicating it here would mean fixing every b-tree bug in
several places. So the SQLite core lives once, in
[`sqlite3/Sqlite3.Database.pq`](../sqlite3/Sqlite3.Database.pq), and this
reader calls it by name. A packaged single-file build may come later.

## How it works

A GeoPackage is a SQLite 3 database, so the reader delegates all SQLite-level
work (b-trees, records, overflow pages, DDL parsing) to `Sqlite3.Database`
and consumes its navigation table. On top of that it reads the
`gpkg_contents` catalog to enumerate layers and `gpkg_geometry_columns` to
find each layer's geometry column.

Each geometry cell is a GeoPackageBinary blob: a `GP` magic, a version byte,
a flags byte (byte order, envelope shape, empty flag, extended flag), the
SRS id, an optional min/max envelope, then a standard ISO WKB geometry. The
reader skips the envelope (it is derivable), decodes the WKB recursively,
and prints WKT with invariant-culture round-trip number formatting.

The format is defined by the OGC GeoPackage Encoding Standard, with the
geometry encoding in its Annex on the GeoPackageBinary format and ISO WKB.

## Testing

Fixtures in [`test/`](test/) are small, synthetic, and generated by
[`test/make_fixtures.py`](test/make_fixtures.py) with hand-built geometry
blobs (no GDAL involved); [`test/expected.md`](test/expected.md) describes
what each table proves and the exact expected WKT. The geometry decode logic
is mirrored in [`test/mirror.py`](test/mirror.py) and validated by
[`test/check_mirror.py`](test/check_mirror.py), cell by cell against shapely
(an independent WKB reader wrapping GEOS) and against hand-written expected
literals.
