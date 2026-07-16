// Read SQLite database files in pure Power Query M.
// No ODBC, no ADO.NET provider, no Python/R, no custom connector required.
// Paste into a blank query, or wrap as a function in your PBIX / dataflow.
//
// Usage:
//   let
//       SQLite = <this expression>,
//       db  = SQLite(File.Contents("C:\path\to\your.db")),   // nav table of tables
//       tbl = db{[Name = "my_table"]}[Data]
//   in
//       tbl
//
// Supported: ordinary rowid tables, all serial types, overflow pages,
//            INTEGER PRIMARY KEY rowid aliasing, UTF-8/UTF-16LE/UTF-16BE,
//            ALTER TABLE ADD COLUMN short records, multi-level b-trees.
// Not supported: WITHOUT ROWID tables (index b-tree layout), virtual tables,
//            reading un-checkpointed data from a -wal file (see notes at end).
// Precision: integers beyond 2^53 lose precision (M numbers are doubles).

(dbBlob as binary) as table =>
let
    bin = Binary.Buffer(dbBlob),

    //==================== low-level byte access ====================
    Slice = (b as binary, offset as number, count as number) as binary =>
        if count <= 0 then #binary({})
        else Binary.Range(b, offset, count),

    UInt16BEFormat = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger16, ByteOrder.BigEndian),
    UInt32BEFormat = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger32, ByteOrder.BigEndian),
    
    Float64BEFormat = BinaryFormat.ByteOrder(BinaryFormat.Double, ByteOrder.BigEndian),
    ReadByte = (b as binary, offset as number) as number => BinaryFormat.Byte(Binary.Range(b, offset, 1)),
    UIntBE = (b as binary) as number => List.Accumulate(Binary.ToList(b), 0, (s, c) => s * 256 + c),
    IntBE = (b as binary) as number =>
        let
            n = Binary.Length(b),
            u = UIntBE(b)
        in
            if u >= Number.Power(2, 8 * n - 1) then u - Number.Power(2, 8 * n)
            else u,
    
    Byte = (off as number) as number => ReadByte(bin, off),
    UInt2 = (off as number) as number => UInt16BEFormat(Binary.Range(bin, off, 2)),
    UInt4 = (off as number) as number => UInt32BEFormat(Binary.Range(bin, off, 4)),
    Float64BE = (b as binary) as number => Float64BEFormat(b),
    VarintAt = (b as binary, offset as number) as record =>
        let f = (o as number, v as number, n as number) as record =>
                let by = ReadByte(b, o)
                in if n = 8 then [Value = v * 256 + by, Size = 9]
                    else if by < 128 then [Value = v * 128 + by, Size = n + 1]
                    else @f(o + 1, v * 128 + (by - 128), n + 1)
        in
            f(offset, 0, 0),

    //==================== file header ====================
    Magic = Text.FromBinary(Slice(bin, 0, 15), TextEncoding.Utf8),
    ps0   = if Magic <> "SQLite format 3"
            then error Error.Record("SQLiteReader", "Not a SQLite 3 database file", Magic)
            else UInt2(16),
    PageSize   = if ps0 = 1 then 65536 else ps0,
    WriteVer   = Byte(18),                       // 1 = rollback journal, 2 = WAL
    Reserved   = Byte(20),
    Usable     = PageSize - Reserved,
    EncodingId = UInt4(56),
    Enc = if EncodingId = 2 then TextEncoding.Unicode            // UTF-16LE
          else if EncodingId = 3 then TextEncoding.BigEndianUnicode
          else TextEncoding.Utf8,

    // overflow thresholds for table b-tree leaves
    Xmax = Usable - 35,
    Mmin = Number.IntegerDivide((Usable - 12) * 32, 255) - 23,

    //==================== b-tree traversal (table b-trees) ====================
    // returns list of [Rowid = number, Payload = binary]
    CollectCells = (pageNum as number) as list =>
        let
            pageOff = (pageNum - 1) * PageSize,
            base    = pageOff + (if pageNum = 1 then 100 else 0),
            ptype   = Byte(base),
            ncells  = UInt2(base + 3),
            hdrSize = if ptype = 5 then 12 else 8,
            // cell pointer array: 2-byte offsets relative to start of page
            offs = List.Transform({0 .. ncells - 1},
                       (i) => pageOff + UInt2(base + hdrSize + i * 2)),

            ReadLeafCell = (o as number) as record =>
                let
                    pv      = VarintAt(bin, o),
                    P       = pv[Value],
                    rv      = VarintAt(bin, o + pv[Size]),
                    dstart  = o + pv[Size] + rv[Size],
                    payload =
                        if P <= Xmax then Slice(bin, dstart, P)
                        else
                        let
                            K      = Mmin + Number.Mod(P - Mmin, Usable - 4),
                            inline = if K <= Xmax then K else Mmin,
                            head   = Slice(bin, dstart, inline),
                            first  = UInt4(dstart + inline),
                            chunks = List.Generate(
                                () => [pg = first],
                                (s) => s[pg] <> 0,
                                (s) => [pg = UInt4((s[pg] - 1) * PageSize)],
                                (s) => Slice(bin, (s[pg] - 1) * PageSize + 4, Usable - 4)),
                            full   = Binary.Combine({head} & chunks)
                        in
                            Slice(full, 0, P)
                in
                    [Rowid = rv[Value], Payload = payload]
        in
            if ncells = 0 and ptype = 13 then {}
            else if ptype = 13 then
                List.Transform(offs, ReadLeafCell)
            else if ptype = 5 then
                let
                    children  = List.Transform(offs, (o) => UInt4(o)),
                    rightmost = UInt4(base + 8),
                    all       = children & {rightmost}
                in
                    List.Combine(List.Transform(all, (p) => @CollectCells(p)))
            else
                error Error.Record("SQLiteReader",
                    "Page " & Number.ToText(pageNum) &
                    " is not a table b-tree page (type " & Number.ToText(ptype) & ")." &
                    " WITHOUT ROWID tables and indexes are not supported.", null),

    //==================== record (row) decoding ====================
    SerialSize = (st as number) as number =>
        if st = 0 or st = 8 or st = 9 then 0
        else if st <= 4 then st                       // 1..4 -> 1..4 bytes
        else if st = 5 then 6
        else if st = 6 or st = 7 then 8
        else if st >= 12 then Number.IntegerDivide(st - 12, 2)
        else error Error.Record("SQLiteReader", "Reserved serial type " & Number.ToText(st), null),

    DecodeValue = (payload as binary, off as number, st as number) as any =>
        if st = 0 then null
        else if st = 8 then 0
        else if st = 9 then 1
        else if st = 7 then Float64BE(Slice(payload, off, 8))
        else if st <= 6 then IntBE(Slice(payload, off, SerialSize(st)))
        else if Number.Mod(st, 2) = 0 then Slice(payload, off, SerialSize(st))       // blob
        else Text.FromBinary(Slice(payload, off, SerialSize(st)), Enc),              // text

    DecodeRecord = (payload as binary) as list =>
        let
            hv   = VarintAt(payload, 0),
            hlen = hv[Value],
            readTypes = (o as number, acc as list) as list =>
                if o >= hlen then acc
                else let v = VarintAt(payload, o)
                     in @readTypes(o + v[Size], acc & {v[Value]}),
            stypes = readTypes(hv[Size], {}),
            ends   = List.Accumulate(stypes, {hlen}, (s, t) => s & {List.Last(s) + SerialSize(t)}),
            starts = List.RemoveLastN(ends, 1)
        in
            List.Transform(List.Positions(stypes),
                (i) => DecodeValue(payload, starts{i}, stypes{i})),

    //==================== CREATE TABLE parsing (best effort) ====================
    // returns [Columns = list of text, IpkIndex = nullable number]
    ParseColumns = (sql as text) as record =>
        let
            openPos  = Text.PositionOf(sql, "("),
            closePos = Text.PositionOf(sql, ")", Occurrence.Last),
            inner    = Text.Range(sql, openPos + 1, closePos - openPos - 1),
            chars    = Text.ToList(inner),
            walked = List.Accumulate(chars,
                [depth = 0, q = null, cur = "", parts = {}],
                (s, c) =>
                    if s[q] <> null then
                        [depth = s[depth], q = (if c = s[q] then null else s[q]),
                         cur = s[cur] & c, parts = s[parts]]
                    else if c = """" or c = "'" or c = "`" then
                        [depth = s[depth], q = c, cur = s[cur] & c, parts = s[parts]]
                    else if c = "[" then
                        [depth = s[depth], q = "]", cur = s[cur] & c, parts = s[parts]]
                    else if c = "(" then
                        [depth = s[depth] + 1, q = null, cur = s[cur] & c, parts = s[parts]]
                    else if c = ")" then
                        [depth = s[depth] - 1, q = null, cur = s[cur] & c, parts = s[parts]]
                    else if c = "," and s[depth] = 0 then
                        [depth = 0, q = null, cur = "", parts = s[parts] & {s[cur]}]
                    else
                        [depth = s[depth], q = null, cur = s[cur] & c, parts = s[parts]]),
            rawParts = walked[parts] & {walked[cur]},
            norm = (t as text) as text =>
                Text.Trim(Text.Replace(Text.Replace(Text.Replace(t,
                    "#(tab)", " "), "#(cr)", " "), "#(lf)", " ")),
            FirstIdent = (t0 as text) as text =>
                let t = norm(t0),
                    c0 = Text.Start(t, 1)
                in  if c0 = """" or c0 = "'" or c0 = "`" then
                        Text.Range(t, 1, Text.PositionOf(Text.Range(t, 1), c0))
                    else if c0 = "[" then
                        Text.Range(t, 1, Text.PositionOf(t, "]") - 1)
                    else
                        Text.Split(t, " "){0},
            constraintKw = {"PRIMARY", "UNIQUE", "CHECK", "FOREIGN", "CONSTRAINT"},
            colParts = List.Select(rawParts,
                (p) => not List.Contains(constraintKw, Text.Upper(FirstIdent(p)))),
            cols = List.Transform(colParts, FirstIdent),
            ipkCandidates = List.Select(List.Positions(colParts),
                (i) => let u = Text.Upper(norm(colParts{i}))
                       in  Text.Contains(u, "INTEGER") and Text.Contains(u, "PRIMARY KEY")),
            ipk = if List.Count(ipkCandidates) = 1 then ipkCandidates{0} else null
        in
            [Columns = cols, IpkIndex = ipk],

    //==================== table materialization ====================
    DecodeTable = (rootPage as number, sql as text) as table =>
        let
            parsed = ParseColumns(sql),
            cols   = parsed[Columns],
            ipk    = parsed[IpkIndex],
            ncols  = List.Count(cols),
            cells  = CollectCells(rootPage),
            rows = List.Transform(cells, (c) =>
                let
                    vals   = DecodeRecord(c[Payload]),
                    padded = vals &
                             List.Repeat({null}, List.Max({0, ncols - List.Count(vals)})),
                    fixed  = if ipk = null then padded
                             else List.Transform(List.Positions(padded),
                                     (i) => if i = ipk and padded{i} = null
                                            then c[Rowid] else padded{i})
                in fixed),
            result = try Table.FromRows(rows, cols)
                     otherwise Table.FromRows(rows)   // schema-parse mismatch fallback
        in
            result,

    //==================== sqlite_master / navigation ====================
    masterCells = CollectCells(1),
    masterRows  = List.Transform(masterCells, (c) => DecodeRecord(c[Payload])),
    master      = Table.FromRows(
                      List.Transform(masterRows,
                          (r) => r & List.Repeat({null}, List.Max({0, 5 - List.Count(r)}))),
                      {"type", "name", "tbl_name", "rootpage", "sql"}),

    userTables = Table.SelectRows(master,
        each [type] = "table" and not Text.StartsWith([name], "sqlite_")),

    nav0 = Table.AddColumn(userTables, "Data", each
        let rp = [rootpage], sq = [sql] in
        if rp = null or rp = 0 then
            error Error.Record("SQLiteReader", "Virtual table — no b-tree storage", [name])
        else if Text.Contains(Text.Upper(sq), "WITHOUT ROWID") then
            error Error.Record("SQLiteReader", "WITHOUT ROWID tables are not supported", [name])
        else DecodeTable(rp, sq),
        type table),

    nav = Table.SelectColumns(
              Table.RenameColumns(nav0, {{"name", "Name"}, {"rootpage", "RootPage"}, {"sql", "SQL"}}),
              {"Name", "RootPage", "SQL", "Data"})
              meta [
                  SQLite.PageSize   = PageSize,
                  SQLite.Encoding   = EncodingId,
                  SQLite.WalMode    = (WriteVer = 2)   // true => a -wal file may hold newer data
              ]
in
    nav
