// SPDX-License-Identifier: Apache-2.0
//
// Xlsb.Workbook.pq — read Excel Binary Workbooks (.xlsb) in pure Power Query M.
// No ACE OLEDB provider, no gateway software, no custom connector required.
// Paste into a blank query (name it Xlsb.Workbook), or wrap as a function in your PBIX / dataflow.
//
// Usage:
//   let
//       Xlsb.Workbook = <this expression>,
//       wb    = Xlsb.Workbook(File.Contents("C:\path\to\file.xlsb")),  // nav table of sheets
//       sheet = wb{[Name = "Sheet1"]}[Data]
//   in
//       sheet
//
// Options (optional second argument, all keys optional):
//   IncludeHiddenSheets  logical, default false — list hidden and very-hidden sheets
//                        in the navigation table (a Hidden column marks them).
//   PromoteHeaders       logical, default false — use each sheet's first row as
//                        column headers.
//   DetectDates          logical, default true — convert numbers whose cell format
//                        is a date/time format into datetime values. Set false to
//                        get raw Excel serial numbers.
//   MaxRows              number — return at most this many rows per sheet.
//   Strict               logical, default false — when true, tolerated malformations
//                        become errors (shared-string index out of range, stray
//                        cells before any row record).
//
// Supported: BIFF12 worksheets; shared, inline and formula-cached strings;
//            RK-packed and full-precision numbers; booleans; error cells; blank
//            (styled) cells; cached formula results; hidden sheets; date/time
//            detection from builtin and custom number formats; the 1904 date
//            system; stored and deflated ZIP entries.
// Not supported: encrypted workbooks (they are CFB files, not ZIP — clear error);
//            Zip64 archives (clear error); live formula evaluation (the cached
//            result is returned); pivot caches, tables, comments and other
//            non-cell content; charts and macros (ignored).
// Precision: Excel serial numbers are IEEE doubles and convert to datetime at
//            sub-millisecond precision. Serials 1..59 use the 1900-02-28 display
//            convention (matching Excel, not OLE); the fictitious 1900-02-29
//            (serial 60) becomes 1900-03-01.
// Output:    a navigation table (Name, Data, Hidden, ItemKind, ItemName, IsLeaf)
//            of the worksheets, with Xlsb.Date1904 in the table metadata.

(source as binary, optional options as nullable record) as table =>
let
    bin   = Binary.Buffer(source),
    total = Binary.Length(bin),

    opts      = if options = null then [] else options,
    OptHidden = Record.FieldOrDefault(opts, "IncludeHiddenSheets", false) = true,
    OptPromote= Record.FieldOrDefault(opts, "PromoteHeaders", false) = true,
    OptDates  = Record.FieldOrDefault(opts, "DetectDates", true) = true,
    OptMaxRows= Record.FieldOrDefault(opts, "MaxRows", null),
    OptStrict = Record.FieldOrDefault(opts, "Strict", false) = true,

    //==================== low-level byte access ====================
    Slice = (b as binary, offset as number, count as number) as binary =>
        if count <= 0 then #binary({})
        else if offset = 0 then BinaryFormat.Binary(count)(b)
        else BinaryFormat.Record([
                Skip = BinaryFormat.Binary(offset),
                Data = BinaryFormat.Binary(count)
             ])(b)[Data],

    UIntLEOf = (b as binary) as number =>                      // little-endian
        List.Accumulate(List.Reverse(Binary.ToList(b)), 0, (s, c) => s * 256 + c),

    ByteAt  = (b as binary, off as number) as number => Binary.ToList(Slice(b, off, 1)){0},
    UInt2At = (b as binary, off as number) as number => UIntLEOf(Slice(b, off, 2)),
    UInt4At = (b as binary, off as number) as number => UIntLEOf(Slice(b, off, 4)),
    Float8At = (b as binary, off as number) as number =>
        BinaryFormat.ByteOrder(BinaryFormat.Double, ByteOrder.LittleEndian)(Slice(b, off, 8)),

    //==================== ZIP container ====================
    // End-of-central-directory: signature 0x06054B50 within the last 64 KB + 22.
    EocdScanMax = List.Min({total - 22, 65557}),
    EocdOff =
        let hits = List.Select({0 .. EocdScanMax},
                       (p) => UInt4At(bin, total - 22 - p) = 0x06054B50)
        in  if total < 22 or List.IsEmpty(hits)
            then error Error.Record("DataFormat.Error",
                     "Not a ZIP archive — no end-of-central-directory record. " &
                     "Encrypted .xlsb files are CFB containers and are not supported.",
                     [FileSize = total])
            else total - 22 - List.First(hits),

    CdCount  = UInt2At(bin, EocdOff + 10),
    CdOffset = UInt4At(bin, EocdOff + 16),
    Zip64Check =
        if CdCount = 0xFFFF or CdOffset = 0xFFFFFFFF
        then error Error.Record("DataFormat.Error", "Zip64 archives are not supported.", null)
        else CdOffset,

    // central directory entries: [Name, LocalOffset, Method, CompressedSize]
    CdEntryAt = (o as number) as record =>
        let sig      = UInt4At(bin, o),
            nameLen  = UInt2At(bin, o + 28),
            extraLen = UInt2At(bin, o + 30),
            cmtLen   = UInt2At(bin, o + 32)
        in  if sig <> 0x02014B50
            then error Error.Record("DataFormat.Error", "Corrupt ZIP central directory.", [Offset = o])
            else [Name        = Text.FromBinary(Slice(bin, o + 46, nameLen), TextEncoding.Utf8),
                  Method      = UInt2At(bin, o + 10),
                  CompSize    = UInt4At(bin, o + 20),
                  LocalOffset = UInt4At(bin, o + 42),
                  Next        = o + 46 + nameLen + extraLen + cmtLen],

    Entries = List.Generate(
        () => [N = 0, E = if CdCount = 0 then null else CdEntryAt(Zip64Check)],
        (s) => s[E] <> null,
        (s) => [N = s[N] + 1, E = if s[N] + 1 >= CdCount then null else CdEntryAt(s[E][Next])],
        (s) => s[E]),

    PartFind = (name as text) as nullable record =>
        let hits = List.Select(Entries, (e) => e[Name] = name)
        in  if List.IsEmpty(hits) then null else hits{0},

    // the local header repeats name/extra lengths, which may differ from the CD copy
    PartContent = (name as text) as binary =>
        let e  = PartFind(name),
            e2 = if e = null
                 then error Error.Record("DataFormat.Error",
                          "Workbook part """ & name & """ is missing from the archive.", null)
                 else e,
            nl   = UInt2At(bin, e2[LocalOffset] + 26),
            el   = UInt2At(bin, e2[LocalOffset] + 28),
            data = Slice(bin, e2[LocalOffset] + 30 + nl + el, e2[CompSize])
        in
            if e2[Method] = 0 then Binary.Buffer(data)
            else if e2[Method] = 8 then Binary.Buffer(Binary.Decompress(data, Compression.Deflate))
            else error Error.Record("DataFormat.Error",
                     "Unsupported ZIP compression method " & Number.ToText(e2[Method]) &
                     " (only stored and deflate occur in .xlsb).", [Part = name]),

    //==================== BIFF12 record walk ====================
    // record id: 1 byte, or 2 bytes when the first has the high bit set (the id value
    // keeps both bytes); record length: 1-4 bytes, 7 bits each, high bit = continuation.
    RecAt = (part as binary, partLen as number, pos as number) as record =>
        let b0     = ByteAt(part, pos),
            idSize = if b0 >= 128 then 2 else 1,
            rid    = if b0 >= 128 then b0 + ByteAt(part, pos + 1) * 256 else b0,
            LenAt  = (o as number, acc as number, scale as number, n as number) as record =>
                let b = ByteAt(part, o)
                in  if b < 128 or n = 3 then [Value = acc + Number.Mod(b, 128) * scale, Size = n + 1]
                    else @LenAt(o + 1, acc + (b - 128) * scale, scale * 128, n + 1),
            l = LenAt(pos + idSize, 0, 1, 0)
        in  [Rid = rid, Off = pos + idSize + l[Size], Len = l[Value],
             Next = pos + idSize + l[Size] + l[Value]],

    RecordsOf = (part as binary) as list =>
        let partLen = Binary.Length(part)
        in  List.Generate(
                () => if partLen = 0 then null else RecAt(part, partLen, 0),
                (r) => r <> null,
                (r) => if r[Next] >= partLen then null else RecAt(part, partLen, r[Next])),

    // XLWideString: cch (4 bytes) + cch UTF-16LE code units
    WideStrAt = (part as binary, off as number) as record =>
        let cch = UInt4At(part, off)
        in  [Text = Text.FromBinary(Slice(part, off + 4, cch * 2), TextEncoding.Unicode),
             Size = 4 + cch * 2],

    //==================== workbook part: sheets + date system ====================
    WbPart = PartContent("xl/workbook.bin"),
    WbRecs = List.Buffer(RecordsOf(WbPart)),

    Date1904 =
        let props = List.Select(WbRecs, (r) => r[Rid] = 0x0199)      // BrtWbProp
        in  not List.IsEmpty(props)
            and Number.BitwiseAnd(ByteAt(WbPart, props{0}[Off]), 1) = 1,

    // BrtBundleSh: hsState (4), iTabID (4), strRelID (nullable wide), strName (wide)
    Bundles = List.Transform(
        List.Select(WbRecs, (r) => r[Rid] = 0x019C),
        (r) => let o     = r[Off],
                   hs    = UInt4At(WbPart, o),
                   cch   = UInt4At(WbPart, o + 8),
                   relid = if cch = 0xFFFFFFFF then [Text = null, Size = 4]
                           else WideStrAt(WbPart, o + 8),
                   name  = WideStrAt(WbPart, o + 8 + relid[Size])
               in  [Name = name[Text], RelId = relid[Text], Hidden = hs <> 0]),

    BundleCheck = if List.IsEmpty(Bundles)
        then error Error.Record("DataFormat.Error",
                 "xl/workbook.bin lists no sheets — not a valid .xlsb workbook.", null)
        else Bundles,

    //==================== workbook rels: rId -> part path ====================
    RelsDoc  = Xml.Document(PartContent("xl/_rels/workbook.bin.rels")),
    AttrOf   = (attrs as table, name as text) as nullable text =>
        let hits = Table.ToRecords(Table.SelectRows(attrs, each [Name] = name))
        in  if List.IsEmpty(hits) then null else hits{0}[Value],
    Rels = List.Transform(
        Table.ToRecords(Table.SelectRows(RelsDoc{0}[Value], each [Name] = "Relationship")),
        (r) => [Id     = AttrOf(r[Attributes], "Id"),
                Type   = AttrOf(r[Attributes], "Type"),
                Target = AttrOf(r[Attributes], "Target")]),

    RelOf = (relId as nullable text) as nullable record =>
        let hits = if relId = null then {} else List.Select(Rels, (r) => r[Id] = relId)
        in  if List.IsEmpty(hits) then null else hits{0},

    RelTarget = (relId as nullable text) as text =>
        let rel = RelOf(relId),
            target = if rel = null or rel[Target] = null
                     then error Error.Record("DataFormat.Error",
                              "Sheet relationship """ & (if relId = null then "(null)" else relId) &
                              """ is missing from xl/_rels/workbook.bin.rels.", null)
                     else rel[Target]
        in  if Text.StartsWith(target, "/") then Text.Range(target, 1) else "xl/" & target,

    // chartsheets, macro sheets and dialog sheets are bundles too — only
    // relationships of type ".../worksheet" hold cell data
    IsWorksheet = (relId as nullable text) as logical =>
        let rel = RelOf(relId)
        in  rel <> null and rel[Type] <> null and Text.EndsWith(rel[Type], "/worksheet"),

    //==================== shared strings (optional part) ====================
    // BrtSSTItem: flags byte, then XLWideString (rich runs / phonetics ignored)
    SstStrings = List.Buffer(
        if PartFind("xl/sharedStrings.bin") = null then {}
        else
            let ss = PartContent("xl/sharedStrings.bin")
            in  List.Transform(
                    List.Select(RecordsOf(ss), (r) => r[Rid] = 0x0013),
                    (r) => WideStrAt(ss, r[Off] + 1)[Text])),

    SstAt = (i as number) as any =>
        if i < List.Count(SstStrings) then SstStrings{i}
        else if OptStrict then error Error.Record("DataFormat.Error",
                 "Shared-string index out of range.", [Index = i, Count = List.Count(SstStrings)])
        else null,

    //==================== styles: which style indexes are dates ====================
    // BrtXF inside the BrtBeginCellXFs section: iFmt is the u16 at offset 2.
    // BrtFmt: ifmt (2 bytes) + format-code wide string.
    Styles =
        if PartFind("xl/styles.bin") = null then [Formats = [], XfIfmts = {}]
        else
            let st   = PartContent("xl/styles.bin"),
                recs = RecordsOf(st),
                walk = List.Accumulate(recs,
                    [inCellXfs = false, fmts = {}, xfs = {}],
                    (s, r) =>
                        if r[Rid] = 0x04E9 then [inCellXfs = true,  fmts = s[fmts], xfs = s[xfs]]
                        else if r[Rid] = 0x04EA then [inCellXfs = false, fmts = s[fmts], xfs = s[xfs]]
                        else if r[Rid] = 0x002C then
                            [inCellXfs = s[inCellXfs],
                             fmts = s[fmts] & {{UInt2At(st, r[Off]), WideStrAt(st, r[Off] + 2)[Text]}},
                             xfs  = s[xfs]]
                        else if r[Rid] = 0x002F and s[inCellXfs] then
                            [inCellXfs = s[inCellXfs], fmts = s[fmts],
                             xfs = s[xfs] & {UInt2At(st, r[Off] + 2)}]
                        else s)
            in  [Formats = Record.FromList(
                     List.Transform(walk[fmts], (f) => f{1}),
                     List.Transform(walk[fmts], (f) => Number.ToText(f{0}))),
                 XfIfmts = walk[xfs]],

    XfIfmts    = List.Buffer(Styles[XfIfmts]),
    FormatsRec = Styles[Formats],

    // builtin date/time number formats per ECMA-376 / [MS-XLSB]
    DateBuiltins = List.Buffer({14..22} & {27..36} & {45, 46, 47} & {50..58} & {71..81}),

    // custom format codes: a date format contains y/m/d/h/s outside quoted runs,
    // backslash escapes and [] blocks (except elapsed [h] [m] [s], which count)
    IsDateCode = (code as text) as logical =>
        let walked = List.Accumulate(Text.ToList(code),
                [q = false, esc = false, blk = false, blk0 = null, hit = false],
                (s, c) =>
                    if s[hit] then s
                    else if s[esc] then [q = s[q], esc = false, blk = s[blk], blk0 = s[blk0], hit = false]
                    else if s[q] then [q = c <> """", esc = false, blk = false, blk0 = null, hit = false]
                    else if s[blk] then
                        if c = "]" then
                            [q = false, esc = false, blk = false, blk0 = null,
                             hit = List.Contains({"h", "m", "s"}, Text.Lower(s[blk0] ?? ""))]
                        else [q = false, esc = false, blk = true,
                              blk0 = if s[blk0] = null then c else s[blk0], hit = false]
                    else if c = """" then [q = true, esc = false, blk = false, blk0 = null, hit = false]
                    else if c = "\" then [q = false, esc = true, blk = false, blk0 = null, hit = false]
                    else if c = "[" then [q = false, esc = false, blk = true, blk0 = null, hit = false]
                    else [q = false, esc = false, blk = false, blk0 = null,
                          hit = List.Contains({"y", "m", "d", "h", "s"}, Text.Lower(c))])
        in  walked[hit],

    IsDateStyle = (style as number) as logical =>
        OptDates and (
        let ifmt = if style < List.Count(XfIfmts) then XfIfmts{style} else 0,
            code = Record.FieldOrDefault(FormatsRec, Number.ToText(ifmt), null)
        in  List.Contains(DateBuiltins, ifmt)
            or (code <> null and IsDateCode(code))),

    // Excel serial -> datetime. Serials below 61 use the 1899-12-31 epoch so that
    // displayed dates match Excel (Lotus leap-year bug); 60 becomes 1900-03-01.
    SerialToDateTime = (v as number) as datetime =>
        if Date1904 then #datetime(1904, 1, 1, 0, 0, 0) + #duration(0, 0, 0, v * 86400)
        else if v >= 61 then #datetime(1899, 12, 30, 0, 0, 0) + #duration(0, 0, 0, v * 86400)
        else #datetime(1899, 12, 31, 0, 0, 0) + #duration(0, 0, 0, v * 86400),

    NumOrDate = (v as number, style as number) as any =>
        if IsDateStyle(style) then SerialToDateTime(v) else v,

    //==================== cell values ====================
    // RK: bit 0 = divide by 100, bit 1 = 30-bit signed integer; otherwise the
    // 30 payload bits are the high bits of an IEEE double.
    RkValue = (v as number) as number =>
        let x100 = Number.BitwiseAnd(v, 1) = 1,
            isInt = Number.BitwiseAnd(v, 2) = 2,
            base =
                if isInt then
                    let n = Number.IntegerDivide(v, 4)
                    in  if n >= 536870912 then n - 1073741824 else n   // 2^29, 2^30
                else
                    let m  = v - Number.BitwiseAnd(v, 3),
                        by = {0, 0, 0, 0,
                              Number.Mod(m, 256),
                              Number.Mod(Number.IntegerDivide(m, 256), 256),
                              Number.Mod(Number.IntegerDivide(m, 65536), 256),
                              Number.IntegerDivide(m, 16777216)}
                    in  BinaryFormat.ByteOrder(BinaryFormat.Double, ByteOrder.LittleEndian)(#binary(by))
        in  if x100 then base / 100 else base,

    ErrorText = (code as number) as text =>
        if code = 0x00 then "#NULL!" else if code = 0x07 then "#DIV/0!"
        else if code = 0x0F then "#VALUE!" else if code = 0x17 then "#REF!"
        else if code = 0x1D then "#NAME?" else if code = 0x24 then "#NUM!"
        else if code = 0x2A then "#N/A" else if code = 0x2B then "#GETTING_DATA"
        else "#ERR" & Number.ToText(code),

    CellError = (code as number) as any =>
        error Error.Record("Expression.Error",
            "The Excel cell contains the error value " & ErrorText(code) & ".", null),

    //==================== sheet part -> cells ====================
    // cell records 0x01-0x0B share the header: column (4 bytes), style (low 24 bits
    // of the next 4). BrtRowHdr (0x00) carries the current row.
    CellsOf = (part as binary) as list =>
        let
            recs = List.Buffer(RecordsOf(part)),
            n    = List.Count(recs),
            StepAt = (i as number, prevRow as number) as record =>
                let r   = recs{i},
                    rid = r[Rid],
                    o   = r[Off],
                    row = if rid = 0 then UInt4At(part, o) else prevRow,
                    cell =
                        if rid = 0 or rid > 0x0B or r[Len] < 8 then null
                        else
                            let c     = UInt4At(part, o),
                                style = Number.Mod(UInt4At(part, o + 4), 16777216),
                                p     = o + 8,
                                v =
                                    if rid = 0x01 then null                                   // BrtCellBlank
                                    else if rid = 0x02 then NumOrDate(RkValue(UInt4At(part, p)), style)
                                    else if rid = 0x03 then CellError(ByteAt(part, p))
                                    else if rid = 0x04 then ByteAt(part, p) <> 0
                                    else if rid = 0x05 then NumOrDate(Float8At(part, p), style)
                                    else if rid = 0x06 then WideStrAt(part, p)[Text]          // inline
                                    else if rid = 0x07 then SstAt(UInt4At(part, p))
                                    else if rid = 0x08 then WideStrAt(part, p)[Text]          // fmla string
                                    else if rid = 0x09 then NumOrDate(Float8At(part, p), style)
                                    else if rid = 0x0A then ByteAt(part, p) <> 0
                                    else CellError(ByteAt(part, p))
                            in  [R = row, C = c, V = v]
                in  [I = i, Row = row, Cell = cell],
            states = List.Generate(
                () => if n = 0 then null else StepAt(0, 0),
                (s) => s <> null,
                (s) => if s[I] + 1 >= n then null else StepAt(s[I] + 1, s[Row]),
                (s) => s[Cell])
        in
            List.RemoveNulls(states),

    //==================== cells -> table ====================
    GridFromCells = (cells0 as list) as table =>
        let
            cells = List.Buffer(cells0),
            ncols = if List.IsEmpty(cells) then 0
                    else 1 + List.Max(List.Transform(cells, each [C])),
            nrowsAll = if List.IsEmpty(cells) then 0
                       else 1 + List.Max(List.Transform(cells, each [R])),
            nrows = if OptMaxRows = null then nrowsAll else List.Min({nrowsAll, OptMaxRows}),
            grouped = Table.Sort(
                Table.Group(Table.FromRecords(cells, type table [R = number, C = number, V = any]),
                            {"R"}, {{"Cells", each Table.ToRecords(_), type any}}),
                {"R", Order.Ascending}),
            MakeRow = (rcs as list) as list =>
                let filled = List.Accumulate(rcs, {}, (acc, cl) =>
                        let pad = cl[C] - List.Count(acc)
                        in  if pad < 0 then acc                       // duplicate cell: keep first
                            else acc & List.Repeat({null}, pad) & {cl[V]})
                in  filled & List.Repeat({null}, ncols - List.Count(filled)),
            rowMap = Record.FromList(
                List.Transform(Table.ToRecords(grouped), (g) => MakeRow(g[Cells])),
                List.Transform(Table.ToRecords(grouped), (g) => Number.ToText(g[R]))),
            emptyRow = List.Repeat({null}, ncols),
            rows = List.Transform({0 .. nrows - 1},
                       (r) => Record.FieldOrDefault(rowMap, Number.ToText(r), emptyRow)),
            colNames = List.Transform({1 .. ncols}, (i) => "Column" & Number.ToText(i)),
            base = if ncols = 0 then #table({}, {})
                   else Table.FromRows(if nrows = 0 then {} else rows, colNames)
        in
            if OptPromote and ncols > 0 then Table.PromoteHeaders(base) else base,

    SheetTable = (relId as nullable text) as table =>
        GridFromCells(CellsOf(PartContent(RelTarget(relId)))),

    //==================== navigation table ====================
    Shown = List.Select(BundleCheck,
        (b) => IsWorksheet(b[RelId]) and (OptHidden or not b[Hidden])),

    NavRows = List.Transform(Shown, (b) =>
        {b[Name], SheetTable(b[RelId]), b[Hidden], "Sheet", "Sheet", true}),

    NavType =
        Type.AddTableKey(
            type table [Name = text, Data = any, Hidden = logical,
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
              #table({"Name", "Data", "Hidden", "ItemKind", "ItemName", "IsLeaf"}, NavRows),
              NavType)
          meta [Xlsb.Date1904 = Date1904]
in
    Nav
