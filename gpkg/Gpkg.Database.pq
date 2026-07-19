// SPDX-License-Identifier: Apache-2.0
//
// Gpkg.Database.pq — read OGC GeoPackage files (.gpkg) in pure Power Query M.
// No GDAL, no spatial ODBC driver, no custom connector, no gateway software.
//
// DEPENDENCY: this reader calls Sqlite3.Database, the SQLite core from
// sqlite3/Sqlite3.Database.pq in the same repository. Paste BOTH files as
// queries, named exactly Sqlite3.Database and Gpkg.Database. This is the one
// deliberate exception to the repository's single-file rule: a GeoPackage is
// a SQLite database, the core is the largest piece of code involved, and
// b-tree bugfixes should land in one place.
//
// Usage:
//   let
//       gp  = Gpkg.Database(File.Contents("C:\path\to\your.gpkg")),  // nav table
//       tbl = gp{[Name = "my_layer"]}[Data]
//   in
//       tbl
//
// Options (optional second argument, all keys optional):
//   GeometryFormat        text, default "WKT" — how geometry columns are
//                         returned: "WKT" (well-known text, what Power BI map
//                         visuals consume), "WKB" (raw ISO well-known binary,
//                         GeoPackageBinary header stripped), or
//                         "GeoPackageBinary" (blob untouched).
//   IncludeSystemTables   logical, default false — also list the gpkg_*
//                         catalog tables in the navigation table.
//   MaxRows               number — return at most this many rows per table.
//   Strict                logical, default false — when true, tolerated
//                         malformations become errors (undecodable geometry
//                         blobs return null by default).
//
// Supported: features, attributes and tiles tables listed in gpkg_contents;
//            all ISO WKB geometry types (Point, LineString, Polygon,
//            MultiPoint, MultiLineString, MultiPolygon, GeometryCollection)
//            in XY, Z, M and ZM dimensions; per-geometry and per-header byte
//            order (both endiannesses); all envelope indicators; empty and
//            null geometries. SQLite-level support and limits are those of
//            Sqlite3.Database.
// Not supported: extended (extension-defined) GeoPackageBinary payloads and
//            EWKB — null by default, clear error under Strict; features
//            registered as SQL views (clear error per entry); rtree
//            spatial-index internals are deliberately hidden.
// Precision: integers beyond 2^53 lose precision (M numbers are doubles).
// Output:    a navigation table (Name, DataType, Data, ItemKind, ItemName,
//            IsLeaf), one row per gpkg_contents entry, with
//            Gpkg.ApplicationId and Gpkg.UserVersion in the table metadata.
//            Feature tables carry Gpkg.SrsId / Gpkg.DataType /
//            Gpkg.Description in their metadata.

(source as binary, optional options as nullable record) as table =>
let
    bin = Binary.Buffer(source),

    opts       = if options = null then [] else options,
    OptSystem  = Record.FieldOrDefault(opts, "IncludeSystemTables", false) = true,
    OptMaxRows = Record.FieldOrDefault(opts, "MaxRows", null),
    OptStrict  = Record.FieldOrDefault(opts, "Strict", false) = true,
    OptGeomFmt0 = Record.FieldOrDefault(opts, "GeometryFormat", "WKT"),
    OptGeomFmt = if List.Contains({"WKT", "WKB", "GeoPackageBinary"}, OptGeomFmt0)
                 then OptGeomFmt0
                 else error Error.Record("Expression.Error",
                     "options[GeometryFormat] must be ""WKT"", ""WKB"" or ""GeoPackageBinary"".",
                     OptGeomFmt0),

    //==================== byte access (file header + geometry blobs) ====================
    Slice = (b as binary, offset as number, count as number) as binary =>
        if count <= 0 then #binary({})
        else if offset = 0 then BinaryFormat.Binary(count)(b)
        else BinaryFormat.Record([
                Skip = BinaryFormat.Binary(offset),
                Data = BinaryFormat.Binary(count)
             ])(b)[Data],

    UIntBE = (b as binary) as number =>
        List.Accumulate(Binary.ToList(b), 0, (s, c) => s * 256 + c),

    // endian-parameterised reads for GeoPackageBinary / WKB blobs
    U32At = (b as binary, off as number, little as logical) as number =>
        BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger32,
            if little then ByteOrder.LittleEndian else ByteOrder.BigEndian)
            (Slice(b, off, 4)),
    I32At = (b as binary, off as number, little as logical) as number =>
        BinaryFormat.ByteOrder(BinaryFormat.SignedInteger32,
            if little then ByteOrder.LittleEndian else ByteOrder.BigEndian)
            (Slice(b, off, 4)),
    F64At = (b as binary, off as number, little as logical) as number =>
        BinaryFormat.ByteOrder(BinaryFormat.Double,
            if little then ByteOrder.LittleEndian else ByteOrder.BigEndian)
            (Slice(b, off, 8)),

    //==================== the SQLite core (shared dependency) ====================
    Db = if Text.FromBinary(Slice(bin, 0, 15), TextEncoding.Utf8) <> "SQLite format 3"
         then error Error.Record("DataFormat.Error",
             "Not a GeoPackage: the file is not a SQLite 3 database.", null)
         else Sqlite3.Database(bin),

    TableByName = (nm as text) as table =>
        let m = Table.SelectRows(Db, each [Name] = nm)
        in  if Table.RowCount(m) = 0 then
                error Error.Record("DataFormat.Error",
                    "The database has no """ & nm & """ table" &
                    " (if it is a SQL view, views are not supported).", null)
            else m{0}[Data],

    Truncate = (t as table) as table =>
        if OptMaxRows = null then t else Table.FirstN(t, OptMaxRows),

    //==================== GeoPackage catalog ====================
    contents = if Table.RowCount(Table.SelectRows(Db, each [Name] = "gpkg_contents")) = 0
        then error Error.Record("DataFormat.Error",
            "Not a GeoPackage: the database has no gpkg_contents table.", null)
        else TableByName("gpkg_contents"),

    geomCols = try TableByName("gpkg_geometry_columns")
               otherwise #table({"table_name", "column_name"}, {}),
    GeomColOf = (tname as text) as nullable text =>
        let m = Table.SelectRows(geomCols, each [table_name] = tname)
        in  if Table.RowCount(m) = 0 then null else m{0}[column_name],

    //==================== GeoPackageBinary / WKB decoding ====================
    FmtNum = (v as number) as text => Number.ToText(v, "R", "en-US"),

    // parse one ISO WKB geometry at offset o; returns [Wkt = text, Next = number]
    WkbGeometry = (b as binary, o as number) as record =>
        let
            obyte  = UIntBE(Slice(b, o, 1)),
            little = obyte = 1,
            code   = U32At(b, o + 1, little),
            dim    = Number.IntegerDivide(code, 1000),
            base   = Number.Mod(code, 1000),
            name   = if (obyte <> 0 and obyte <> 1) or dim > 3 or base < 1 or base > 7
                     then error Error.Record("DataFormat.Error",
                         "Unsupported WKB geometry type code " & Number.ToText(code) &
                         " (only ISO WKB Point/LineString/Polygon/Multi*/GeometryCollection" &
                         " in XY/Z/M/ZM are supported).", null)
                     else {"POINT", "LINESTRING", "POLYGON", "MULTIPOINT",
                           "MULTILINESTRING", "MULTIPOLYGON", "GEOMETRYCOLLECTION"}{base - 1}
                          & {"", " Z", " M", " ZM"}{dim},
            ncoord = 2 + (if dim = 3 then 2 else if dim = 1 or dim = 2 then 1 else 0),
            body   = o + 5,

            // n points of ncoord doubles at offset co -> [Pts = list of text, Next]
            CoordText = (co as number, n as number) as record =>
                [Pts = List.Transform({0 .. n - 1}, (i) =>
                          Text.Combine(List.Transform({0 .. ncoord - 1}, (j) =>
                              FmtNum(F64At(b, co + 8 * (i * ncoord + j), little))), " ")),
                 Next = co + 8 * n * ncoord],

            result =
                if base = 1 then
                    let vals = List.Transform({0 .. ncoord - 1},
                                   (j) => F64At(b, body + 8 * j, little)),
                        nxt  = body + 8 * ncoord
                    in  if List.MatchesAll(vals, Number.IsNaN)
                        then [Wkt = name & " EMPTY", Next = nxt]
                        else [Wkt = name & " (" &
                                  Text.Combine(List.Transform(vals, FmtNum), " ") & ")",
                              Next = nxt]
                else if base = 2 then
                    let n = U32At(b, body, little)
                    in  if n = 0 then [Wkt = name & " EMPTY", Next = body + 4]
                        else let c = CoordText(body + 4, n)
                             in  [Wkt = name & " (" & Text.Combine(c[Pts], ", ") & ")",
                                  Next = c[Next]]
                else if base = 3 then
                    let n = U32At(b, body, little)
                    in  if n = 0 then [Wkt = name & " EMPTY", Next = body + 4]
                        else let acc = List.Accumulate({1 .. n},
                                 [Off = body + 4, Parts = {}],
                                 (s, i) =>
                                     let m = U32At(b, s[Off], little),
                                         c = CoordText(s[Off] + 4, m)
                                     in  [Off = c[Next],
                                          Parts = s[Parts] &
                                              {"(" & Text.Combine(c[Pts], ", ") & ")"}])
                             in  [Wkt = name & " (" & Text.Combine(acc[Parts], ", ") & ")",
                                  Next = acc[Off]]
                else  // multi* and geometry collection: n child geometries
                    let n = U32At(b, body, little)
                    in  if n = 0 then [Wkt = name & " EMPTY", Next = body + 4]
                        else let acc = List.Accumulate({1 .. n},
                                 [Off = body + 4, Parts = {}],
                                 (s, i) =>
                                     let g = @WkbGeometry(b, s[Off]),
                                         w = g[Wkt],
                                         // children of typed multis drop their type name
                                         part = if base = 7 then w
                                                else let p = Text.PositionOf(w, "(")
                                                     in  if p < 0 then "EMPTY"
                                                         else Text.Range(w, p)
                                     in  [Off = g[Next], Parts = s[Parts] & {part}])
                             in  [Wkt = name & " (" & Text.Combine(acc[Parts], ", ") & ")",
                                  Next = acc[Off]]
        in
            result,

    // GeoPackageBinary header -> [Little, Empty, Extended, SrsId, WkbOff]
    GpbHeader = (blob as binary) as record =>
        let
            magic = Text.FromBinary(Slice(blob, 0, 2), TextEncoding.Ascii),
            ver   = UIntBE(Slice(blob, 2, 1)),
            flags = if magic <> "GP"
                    then error Error.Record("DataFormat.Error",
                        "Not a GeoPackageBinary geometry blob (bad magic).", magic)
                    else if ver <> 0
                    then error Error.Record("DataFormat.Error",
                        "Unsupported GeoPackageBinary version " & Number.ToText(ver) & ".", null)
                    else UIntBE(Slice(blob, 3, 1)),
            little = Number.BitwiseAnd(flags, 1) = 1,
            envInd = Number.BitwiseAnd(Number.BitwiseShiftRight(flags, 1), 7),
            envDoubles = if envInd > 4
                    then error Error.Record("DataFormat.Error",
                        "Invalid GeoPackageBinary envelope indicator " &
                        Number.ToText(envInd) & ".", null)
                    else {0, 4, 6, 6, 8}{envInd}
        in
            [Little   = little,
             Empty    = Number.BitwiseAnd(flags, 16) <> 0,
             Extended = Number.BitwiseAnd(flags, 32) <> 0,
             SrsId    = I32At(blob, 4, little),
             WkbOff   = 8 + 8 * envDoubles],

    GpbToWkt = (blob as binary) as text =>
        let
            h    = GpbHeader(blob),
            wkt0 = if h[Extended]
                   then error Error.Record("DataFormat.Error",
                       "Extended GeoPackageBinary geometry (extension-defined payload)" &
                       " is not supported.", null)
                   else WkbGeometry(blob, h[WkbOff])[Wkt],
            wkt  = if h[Empty] and not Text.EndsWith(wkt0, " EMPTY")
                   then (let p = Text.PositionOf(wkt0, " (")
                         in  if p < 0 then wkt0 else Text.Start(wkt0, p)) & " EMPTY"
                   else wkt0
        in
            wkt,

    GpbToWkb = (blob as binary) as binary =>
        let h = GpbHeader(blob)
        in  Slice(blob, h[WkbOff], Binary.Length(blob) - h[WkbOff]),

    // permissive by default: undecodable geometry cells become null
    GeomCell = (decode as function) as function =>
        (v) => if v = null then null
               else if v is binary then
                   let r = try decode(v)
                   in  if not r[HasError] then r[Value]
                       else if OptStrict then error r[Error]
                       else null
               else if OptStrict then
                   error Error.Record("DataFormat.Error",
                       "Geometry column holds a non-blob value.", v)
               else null,

    //==================== navigation table ====================
    FeatureTable = (tname as text, srsid as nullable number,
                    dtype as text, descr as nullable text) as table =>
        let
            t    = Truncate(TableByName(tname)),
            gcol = GeomColOf(tname),
            out  = if gcol = null or not Table.HasColumns(t, gcol)
                      or OptGeomFmt = "GeoPackageBinary" then t
                   else if OptGeomFmt = "WKT" then
                       Table.TransformColumns(t,
                           {{gcol, GeomCell(GpbToWkt), type nullable text}})
                   else
                       Table.TransformColumns(t,
                           {{gcol, GeomCell(GpbToWkb), type nullable binary}})
        in
            out meta [Gpkg.SrsId = srsid, Gpkg.DataType = dtype, Gpkg.Description = descr],

    contentRows = Table.ToRecords(contents),
    DataFor = (r as record) as table =>
        let
            tname = r[table_name],
            dtype = r[data_type],
            srsid = Record.FieldOrDefault(r, "srs_id", null),
            descr = Record.FieldOrDefault(r, "description", null)
        in
            if dtype = "features" then FeatureTable(tname, srsid, dtype, descr)
            else Truncate(TableByName(tname))
                 meta [Gpkg.SrsId = srsid, Gpkg.DataType = dtype, Gpkg.Description = descr],

    NavRows = List.Transform(contentRows, (r) =>
        {r[table_name], r[data_type], DataFor(r), "Table", "Table", true}),

    SysNames = if not OptSystem then {}
               else List.Sort(List.Select(Table.Column(Db, "Name"),
                        each Text.StartsWith(_, "gpkg_"))),
    SysRows = List.Transform(SysNames, (nm) =>
        {nm, "system", TableByName(nm), "Table", "Table", true}),

    NavType =
        Type.AddTableKey(
            type table [Name = text, DataType = nullable text, Data = any,
                        ItemKind = text, ItemName = text, IsLeaf = logical],
            {"Name"}, true)
        meta [
            NavigationTable.NameColumn = "Name",
            NavigationTable.DataColumn = "Data",
            NavigationTable.ItemKindColumn = "ItemKind",
            Preview.DelayColumn = "ItemName",
            NavigationTable.IsLeafColumn = "IsLeaf"
        ],

    Nav = Value.ReplaceType(
              #table({"Name", "DataType", "Data", "ItemKind", "ItemName", "IsLeaf"},
                     NavRows & SysRows),
              NavType)
          meta [
              Gpkg.ApplicationId = Text.FromBinary(Slice(bin, 68, 4), TextEncoding.Ascii),
              Gpkg.UserVersion   = UIntBE(Slice(bin, 60, 4))
          ]
in
    Nav
