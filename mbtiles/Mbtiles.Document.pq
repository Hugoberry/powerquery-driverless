// SPDX-License-Identifier: Apache-2.0
//
// Mbtiles.Document.pq — read MBTiles tilesets (.mbtiles) in pure Power Query M.
// No GDAL, no tile server, no custom connector, no gateway software required.
//
// DEPENDENCY: this reader calls Sqlite3.Database, the SQLite core from
// sqlite3/Sqlite3.Database.pq in the same repository. Paste BOTH files as
// queries, named exactly Sqlite3.Database and Mbtiles.Document. This is the
// one deliberate exception to the repository's single-file rule: an MBTiles
// file is a SQLite database, the core is the largest piece of code involved,
// and b-tree bugfixes should land in one place.
//
// Usage:
//   let
//       ts    = Mbtiles.Document(File.Contents("C:\path\to\your.mbtiles")),
//       tiles = ts{[Name = "Tiles"]}[Data],
//       meta  = ts{[Name = "Metadata"]}[Data]
//   in
//       tiles
//
// Options (optional second argument, all keys optional):
//   DecompressTiles  logical, default null (auto) — MBTiles vector tiles
//                    (format=pbf) are stored gzip-compressed. Auto detects the
//                    gzip signature per tile and decompresses; true forces
//                    decompression (error when a tile is not gzip); false
//                    leaves every tile untouched.
//   MaxRows          number — return at most this many tile rows.
//   Strict           logical, default false — when true, tolerated
//                    malformations become errors (missing metadata table,
//                    a gzip tile that fails to decompress).
//
// Supported: the plain `tiles` table layout (MBTiles 1.x); the deduplicated
//            tippecanoe layout (`map` + `images` tables behind a `tiles`
//            view, joined here in M); raster (png/jpg/webp) and vector (pbf)
//            tile data; UTFGrid `grids` / `grid_data` tables when present.
//            SQLite-level support and limits are those of Sqlite3.Database.
// Not supported: `tiles` views other than the map + images layout (clear
//            error).
// Precision: integer cells decode exactly across the full signed 64-bit range
//            (inherited from Sqlite3.Database); downstream M arithmetic may still
//            coerce to double past 2^53.
// Output:    a navigation table (Name, Data, ItemKind, ItemName, IsLeaf) with
//            Metadata and Tiles entries (plus grids tables when present).
//            Tiles carries zoom_level / tile_column / tile_row exactly as
//            stored (TMS row order, per the MBTiles spec) plus a computed
//            tile_row_xyz column (= 2^zoom - 1 - tile_row) for XYZ/web
//            mercator consumers. The metadata key-value pairs are also
//            attached as a record in the navigation table metadata
//            (Mbtiles.Metadata), alongside Mbtiles.Format.

(source as binary, optional options as nullable record) as table =>
let
    bin = Binary.Buffer(source),

    opts       = if options = null then [] else options,
    OptMaxRows = Record.FieldOrDefault(opts, "MaxRows", null),
    OptStrict  = Record.FieldOrDefault(opts, "Strict", false) = true,
    OptDecomp  = Record.FieldOrDefault(opts, "DecompressTiles", null),

    //==================== the SQLite core (shared dependency) ====================
    Db = if Binary.Length(bin) < 16
            or Text.FromBinary(Binary.Range(bin, 0, 15), TextEncoding.Utf8)
               <> "SQLite format 3"
         then error Error.Record("DataFormat.Error",
             "Not an MBTiles file: the file is not a SQLite 3 database.", null)
         else Sqlite3.Database(bin),

    HasTable = (nm as text) as logical =>
        Table.RowCount(Table.SelectRows(Db, each [Name] = nm)) > 0,

    TableByName = (nm as text) as table =>
        Table.SelectRows(Db, each [Name] = nm){0}[Data],

    Truncate = (t as table) as table =>
        if OptMaxRows = null then t else Table.FirstN(t, OptMaxRows),

    //==================== metadata ====================
    MetadataTable =
        if HasTable("metadata") then TableByName("metadata")
        else if OptStrict then
            error Error.Record("DataFormat.Error",
                "The MBTiles metadata table is missing.", null)
        else #table({"name", "value"}, {}),

    MetadataValue = (key as text) as nullable text =>
        let m = Table.SelectRows(MetadataTable, each [name] = key)
        in  if Table.RowCount(m) = 0 then null else m{0}[value],

    MetadataRecord =
        try Record.FromList(MetadataTable[value], MetadataTable[name]) otherwise null,

    //==================== tiles ====================
    RawTiles =
        if HasTable("tiles") then
            Truncate(TableByName("tiles"))
        else if HasTable("map") and HasTable("images") then
            // deduplicated (tippecanoe) layout: tiles is a view over map + images
            let
                mapT  = Truncate(TableByName("map")),
                imgT  = Table.RenameColumns(TableByName("images"),
                            {{"tile_id", "__tile_id"}}),
                join  = Table.Join(mapT, {"tile_id"}, imgT, {"__tile_id"},
                            JoinKind.LeftOuter)
            in
                Table.RemoveColumns(join, {"tile_id", "__tile_id"})
        else
            error Error.Record("DataFormat.Error",
                "Not a readable MBTiles file: no tiles table and no map + images" &
                " pair (a tiles view over any other layout is not supported).", null),

    IsGzip = (v as binary) as logical =>
        Binary.Length(v) >= 2 and
        List.Accumulate(Binary.ToList(Binary.Range(v, 0, 2)), 0,
            (s, c) => s * 256 + c) = 8075,                       // 1F 8B

    TileCell = (v) =>
        if v = null or not (v is binary) then v
        else if OptDecomp = false then v
        else if OptDecomp = true then
            let r = try Binary.Decompress(v, Compression.GZip)
            in  if not r[HasError] then r[Value]
                else error Error.Record("DataFormat.Error",
                    "DecompressTiles = true, but a tile is not valid gzip data.", null)
        else  // auto: decompress only what carries the gzip signature
            if not IsGzip(v) then v
            else let r = try Binary.Decompress(v, Compression.GZip)
                 in  if not r[HasError] then r[Value]
                     else if OptStrict then error r[Error]
                     else v,

    Tiles0 = if Table.HasColumns(RawTiles, "tile_data")
             then Table.TransformColumns(RawTiles, {{"tile_data", TileCell}})
             else RawTiles,

    // MBTiles rows are TMS (row 0 at the bottom); most consumers want XYZ
    Tiles1 = if Table.HasColumns(Tiles0, {"zoom_level", "tile_row"})
             then Table.AddColumn(Tiles0, "tile_row_xyz",
                      each Number.Power(2, [zoom_level]) - 1 - [tile_row],
                      Int64.Type)
             else Tiles0,
    Tiles  = try Table.ReorderColumns(Tiles1,
                     {"zoom_level", "tile_column", "tile_row", "tile_row_xyz",
                      "tile_data"})
             otherwise Tiles1,

    //==================== navigation table ====================
    GridRows =
        (if HasTable("grids")
         then {{"Grids", Truncate(TableByName("grids")), "Table", "Table", true}}
         else {})
        &
        (if HasTable("grid_data")
         then {{"GridData", Truncate(TableByName("grid_data")), "Table", "Table", true}}
         else {}),

    NavRows = {
        {"Metadata", MetadataTable, "Table", "Table", true},
        {"Tiles", Tiles, "Table", "Table", true}
    } & GridRows,

    NavType =
        Type.AddTableKey(
            type table [Name = text, Data = any, ItemKind = text,
                        ItemName = text, IsLeaf = logical],
            {"Name"}, true)
        meta [
            NavigationTable.NameColumn = "Name",
            NavigationTable.DataColumn = "Data",
            NavigationTable.ItemKindColumn = "ItemKind",
            Preview.DelayColumn = "ItemName",
            NavigationTable.IsLeafColumn = "IsLeaf"
        ],

    Nav = Value.ReplaceType(
              #table({"Name", "Data", "ItemKind", "ItemName", "IsLeaf"}, NavRows),
              NavType)
          meta [
              Mbtiles.Metadata = MetadataRecord,
              Mbtiles.Format   = MetadataValue("format"),
              Mbtiles.Name     = MetadataValue("name")
          ]
in
    Nav
