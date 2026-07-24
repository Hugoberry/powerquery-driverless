// SPDX-License-Identifier: Apache-2.0
//
// AccessReader.Database.pq — read Microsoft Access databases (.mdb, .accdb) in pure Power Query M.
// No ACE OLEDB provider, no ODBC driver, no bitness gamble, no gateway software required.
// Paste into a blank query (name it AccessReader.Database), or wrap as a function in your PBIX / dataflow.
//
// The name is deliberately not Access.Database: that is a built-in engine function,
// and a section document that declares `shared Access.Database` fails to compile,
// so the pasted and the packaged reader would otherwise need different names.
//
// Usage:
//   let
//       AccessReader.Database = <this expression>,
//       db  = AccessReader.Database(File.Contents("C:\path\to\your.accdb")),  // nav table of tables
//       tbl = db{[Name = "MyTable"]}[Data]
//   in
//       tbl
//
// Options (optional second argument, all keys optional):
//   IncludeSystemObjects  logical, default false — include MSys* and other system
//                         tables in the navigation table.
//   MaxRows               number — stop after this many rows per table.
//   Strict                logical, default false — when true, tolerated malformations
//                         become errors (unsupported column types, unknown usage-map
//                         formats instead of a full-file page scan).
//
// Supported: Jet 4 (.mdb, Access 2000-2003) and ACE (.accdb, Access 2007+);
//            all common column types (Byte, Integer, Long, Currency, Single, Double,
//            Date/Time, Text, Memo/Long Text, Yes/No, GUID, Decimal, Binary, OLE,
//            Big Integer); fixed and variable columns; null bitmaps; Unicode-compressed
//            text; single- and multi-page memo/OLE (LVAL) storage; deleted-row and
//            overflow-row bookkeeping; multi-page table definitions; rows written
//            before columns were added.
// Not supported: encrypted or password-protected databases (clear error); Jet 3
//            (.mdb, Access 97 and earlier — clear error); linked tables and queries
//            (they hold no local data and are not listed); indexes (not needed for
//            reading); complex/multi-value and attachment columns decode to the raw
//            long-integer key of the hidden child table.
// Precision: integers beyond 2^53 lose precision (M numbers are doubles); the same
//            applies to Currency beyond 2^53/10000 and wide Decimal values.
// Output:    a navigation table (Name, Data, ItemKind, ItemName, IsLeaf) of the
//            user tables, with Access.Version, Access.Format and Access.CreationDate
//            in the table metadata.

(source as binary, optional options as nullable record) as table =>
let
    bin      = Binary.Buffer(source),
    total    = Binary.Length(bin),
    PageSize = 4096,

    opts       = if options = null then [] else options,
    OptSystem  = Record.FieldOrDefault(opts, "IncludeSystemObjects", false) = true,
    OptMaxRows = Record.FieldOrDefault(opts, "MaxRows", null),
    OptStrict  = Record.FieldOrDefault(opts, "Strict", false) = true,

    //==================== low-level byte access ====================
    Slice = (b as binary, offset as number, count as number) as binary =>
        if count <= 0 then #binary({})
        else Binary.Range(b, offset, count),

    U16Fmt = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger16, ByteOrder.LittleEndian),
    U32Fmt = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger32, ByteOrder.LittleEndian),
    F32Fmt = BinaryFormat.ByteOrder(BinaryFormat.Single, ByteOrder.LittleEndian),
    F64Fmt = BinaryFormat.ByteOrder(BinaryFormat.Double, ByteOrder.LittleEndian),

    ByteOf = (b as binary, off as number) as number => BinaryFormat.Byte(Binary.Range(b, off, 1)),
    U16Of  = (b as binary, off as number) as number => U16Fmt(Slice(b, off, 2)),
    U32Of  = (b as binary, off as number) as number => U32Fmt(Slice(b, off, 4)),
    I16Of  = (b as binary, off as number) as number =>
        let u = U16Of(b, off) in if u >= 32768 then u - 65536 else u,
    I32Of  = (b as binary, off as number) as number =>
        let u = U32Of(b, off) in if u >= 2147483648 then u - 4294967296 else u,
    I64Of  = (b as binary, off as number) as number =>          // beyond 2^53 loses precision
        let lo = U32Of(b, off), hi = U32Of(b, off + 4),
            u  = hi * 4294967296 + lo
        in  if hi >= 2147483648 then u - 18446744073709551616 else u,

    ByteAt = (off as number) as number => ByteOf(bin, off),
    U16    = (off as number) as number => U16Of(bin, off),
    U32    = (off as number) as number => U32Of(bin, off),

    Bit = {1, 2, 4, 8, 16, 32, 64, 128},

    //==================== file header (page 0) ====================
    // Bytes 0x18.. of page 0 are masked with the RC4 keystream of the fixed key
    // C7 DA 39 6B (a format constant, not a secret). Unmasking recovers the
    // database key (non-zero means the file is encrypted) and the creation date.
    Rc4Keystream = (count as number) as list =>
        let
            key = {199, 218, 57, 107},
            ksa = List.Accumulate({0 .. 255}, [S = List.Buffer({0 .. 255}), j = 0], (st, i) =>
                let
                    Si = st[S]{i},
                    j2 = Number.Mod(st[j] + Si + key{Number.Mod(i, 4)}, 256),
                    Sj = st[S]{j2}
                in  [S = List.Buffer(List.ReplaceRange(List.ReplaceRange(st[S], i, 1, {Sj}), j2, 1, {Si})),
                     j = j2]),
            prga = List.Generate(
                () => [i = 0, j = 0, S = ksa[S], n = 0, v = null],
                (st) => st[n] <= count,
                (st) =>
                    let
                        i2 = Number.Mod(st[i] + 1, 256),
                        Si = st[S]{i2},
                        j2 = Number.Mod(st[j] + Si, 256),
                        Sj = st[S]{j2},
                        S2 = List.Buffer(List.ReplaceRange(List.ReplaceRange(st[S], i2, 1, {Sj}), j2, 1, {Si}))
                    in  [i = i2, j = j2, S = S2, n = st[n] + 1, v = S2{Number.Mod(Si + Sj, 256)}],
                (st) => st[v])
        in
            List.RemoveFirstN(prga, 1),

    MagicText = Text.FromBinary(Slice(bin, 4, 15), TextEncoding.Ascii),
    CheckMagic =
        if total < 3 * PageSize
           or (MagicText <> "Standard Jet DB" and MagicText <> "Standard ACE DB")
        then error Error.Record("DataFormat.Error",
                "Not a Microsoft Access database file (missing ""Standard Jet DB"" / ""Standard ACE DB"" signature).",
                [Signature = MagicText])
        else true,

    Version = ByteAt(20),                                       // 0x14
    FormatName =
        if Version = 1 then "Jet 4 (Access 2000-2003)"
        else if Version = 2 then "ACE 12 (Access 2007)"
        else if Version = 3 then "ACE 14 (Access 2010)"
        else if Version = 4 then "ACE 15 (Access 2013)"
        else if Version = 5 then "ACE 16 (Access 2016 or later)"
        else if Version = 6 then "ACE 17"
        else "Unknown version " & Number.ToText(Version) & " (assuming Jet 4 layout)",
    CheckVersion =
        if Version = 0
        then error Error.Record("DataFormat.Error",
                "Jet 3 databases (Access 97 and earlier, 2 KB pages) are not supported. " &
                "Open the file in Access and convert it to the 2000 or later format.", null)
        else true,

    Keystream    = List.Buffer(Rc4Keystream(104)),              // covers up to file offset 0x7F
    HeaderByte   = (fileOff as number) as number =>
        Number.BitwiseXor(ByteAt(fileOff), Keystream{fileOff - 24}),
    DbKey        = List.Accumulate({0 .. 3}, 0, (s, i) => s + HeaderByte(62 + i) * Number.Power(256, i)),  // 0x3E
    CreationDate =
        try #datetime(1899, 12, 30, 0, 0, 0) +
            #duration(0, 0, 0, F64Fmt(Binary.FromList(List.Transform({0 .. 7}, (i) => HeaderByte(114 + i)))) * 86400)
        otherwise null,                                         // 0x72, OLE Automation date
    CheckKey =
        if DbKey <> 0
        then error Error.Record("DataFormat.Error",
                "This database is encrypted (the database key in the header is set). " &
                "Encrypted and password-protected databases are not supported; " &
                "remove the password in Access (Decrypt Database) and try again.", null)
        else true,
    CheckCatalog =
        if ByteAt(2 * PageSize) <> 2
        then error Error.Record("DataFormat.Error",
                "The system catalog page is not readable. The file is most likely " &
                "password-encrypted (Access 2007+ encrypts every page) or corrupt. " &
                "Encrypted databases are not supported.", null)
        else true,

    HeaderOk = CheckMagic and CheckVersion and CheckKey and CheckCatalog,

    //==================== pages and row slots ====================
    // A data page holds a slot directory at 0x0E: one uint16 per row, low 13 bits
    // the row's start offset, bit 15 = deleted, bit 14 = row moved to an overflow
    // page (the slot holds a 4-byte pointer to the real row). A row ends where the
    // previous slot's row starts (slot 0 ends at the page boundary).
    PageOff   = (pg as number) as number => pg * PageSize,
    SlotCount = (pg as number) as number => U16(PageOff(pg) + 12),
    SlotRaw   = (pg as number, r as number) as number => U16(PageOff(pg) + 14 + 2 * r),
    RowBinAt  = (pg as number, r as number) as binary =>
        let
            start = Number.BitwiseAnd(SlotRaw(pg, r), 8191),
            end_  = if r = 0 then PageSize else Number.BitwiseAnd(SlotRaw(pg, r - 1), 8191)
        in
            Slice(bin, PageOff(pg) + start, end_ - start),

    // 4-byte row pointer: low byte = row number, upper 24 bits = page number.
    FindPgRow = (ptr as number) as binary =>
        RowBinAt(Number.IntegerDivide(ptr, 256), Number.Mod(ptr, 256)),

    FollowOverflow = (ptr as number) as binary =>
        let
            pg    = Number.IntegerDivide(ptr, 256),
            r     = Number.Mod(ptr, 256),
            raw   = SlotRaw(pg, r),
            start = Number.BitwiseAnd(raw, 8191)
        in
            if Number.BitwiseAnd(raw, 16384) <> 0                // moved again: keep following
            then @FollowOverflow(U32(PageOff(pg) + start))
            else RowBinAt(pg, r),

    //==================== usage maps ====================
    // A table's set of owned pages. Type 0: 4-byte start page + inline bitmap.
    // Type 1: list of pointers to whole bitmap pages (page type 0x05), each
    // covering (PageSize - 4) * 8 pages. Bit order: LSB = first page.
    BitmapPages = (bytesList as list, basePage as number) as list =>
        List.Combine(List.Transform(List.Positions(bytesList), (i) =>
            let by = bytesList{i}
            in  if by = 0 then {}
                else List.Select(
                        List.Transform({0 .. 7}, (bit) =>
                            if Number.BitwiseAnd(by, Bit{bit}) <> 0 then basePage + i * 8 + bit else null),
                        (p) => p <> null))),

    UsagePages = (mapBin as binary) as nullable list =>
        let mtype = ByteOf(mapBin, 0)
        in
            if mtype = 0 then
                BitmapPages(Binary.ToList(Slice(mapBin, 5, Binary.Length(mapBin) - 5)), U32Of(mapBin, 1))
            else if mtype = 1 then
                List.Combine(List.Transform({0 .. Number.IntegerDivide(Binary.Length(mapBin) - 1, 4) - 1}, (idx) =>
                    let mp = U32Of(mapBin, 1 + 4 * idx)
                    in  if mp = 0 then {}
                        else BitmapPages(Binary.ToList(Slice(bin, PageOff(mp) + 4, PageSize - 4)),
                                         idx * (PageSize - 4) * 8)))
            else if OptStrict then
                error Error.Record("DataFormat.Error",
                    "Unknown usage map type " & Number.ToText(mtype) & ".", null)
            else
                null,                                            // caller falls back to a page scan

    //==================== table definitions (TDEF) ====================
    // A TDEF can span pages (next page pointer at 0x04); pages after the first
    // contribute their bytes from offset 8. Offsets below index the joined stream.
    TdefBin = (pg as number) as binary =>
        let
            pages = List.Generate(() => pg, (p) => p <> 0, (p) => U32(PageOff(p) + 4)),
            parts = List.Transform(List.Positions(pages), (i) =>
                if i = 0 then Slice(bin, PageOff(pages{i}), PageSize)
                else Slice(bin, PageOff(pages{i}) + 8, PageSize - 8))
        in
            if ByteAt(PageOff(pg)) <> 2
            then error Error.Record("DataFormat.Error",
                    "Page " & Number.ToText(pg) & " is not a table definition page.", null)
            else Binary.Combine(parts),

    ParseTdef = (pg as number) as record =>
        let
            b          = Binary.Buffer(TdefBin(pg)),
            numRows    = U32Of(b, 16),                           // 0x10
            numVarCols = U16Of(b, 43),                           // 0x2B
            numCols    = U16Of(b, 45),                           // 0x2D
            numRealIdx = U32Of(b, 51),                           // 0x33
            usedPtr    = U32Of(b, 55),                           // 0x37, row pointer to the used-pages map
            colBase    = 63 + numRealIdx * 12,                   // 0x3F + 12 bytes per real index
            cols0 = List.Transform({0 .. numCols - 1}, (i) =>
                let o = colBase + i * 25 in
                [
                    Type     = ByteOf(b, o),
                    ColNum   = U16Of(b, o + 5),
                    VarIdx   = U16Of(b, o + 7),
                    Scale    = ByteOf(b, o + 12),
                    IsFixed  = Number.BitwiseAnd(ByteOf(b, o + 15), 1) <> 0,
                    FixedOff = U16Of(b, o + 21),
                    Len      = U16Of(b, o + 23)
                ]),
            named = List.Accumulate({0 .. numCols - 1}, [pos = colBase + numCols * 25, cols = {}], (st, i) =>
                let nlen = U16Of(b, st[pos])
                in  [pos  = st[pos] + 2 + nlen,
                     cols = st[cols] & {cols0{i} & [Name = Text.FromBinary(Slice(b, st[pos] + 2, nlen), TextEncoding.Unicode)]}]),
            cols = List.Sort(named[cols], each [ColNum])
        in
            [TdefPg = pg, Cols = cols, NumVarCols = numVarCols, UsedPtr = usedPtr, NumRows = numRows],

    //==================== text decoding ====================
    // Jet 4 text is UTF-16LE. A leading FF FE marks "Unicode compression": runs of
    // one byte per character (high byte zero), with 0x00 toggling to raw UTF-16LE
    // runs and back. Decoded units are reassembled and read as UTF-16LE so that
    // surrogate pairs survive.
    DecodeText = (raw as binary) as text =>
        let len = Binary.Length(raw)
        in
            if len = 0 then ""
            else if len >= 2 and ByteOf(raw, 0) = 255 and ByteOf(raw, 1) = 254 then
                if len = 2 then ""
                else let
                    bytes = List.Buffer(Binary.ToList(raw)),
                    Step  = (pos as number, comp as logical) as record =>
                        let b0 = bytes{pos}
                        in  if b0 = 0 then
                                [Next = pos + 1, Comp = not comp, Unit = null]
                            else if comp then
                                [Next = pos + 1, Comp = comp, Unit = b0]
                            else
                                [Next = pos + 2, Comp = comp,
                                 Unit = b0 + 256 * (if pos + 1 < len then bytes{pos + 1} else 0)],
                    walk  = List.Generate(
                        () => Step(2, true),
                        (st) => st <> null,
                        (st) => if st[Next] >= len then null else Step(st[Next], st[Comp]),
                        (st) => st[Unit]),
                    units = List.RemoveNulls(walk),
                    utf16 = List.Combine(List.Transform(units, (u) =>
                                {Number.Mod(u, 256), Number.IntegerDivide(u, 256)}))
                in
                    Text.FromBinary(Binary.FromList(utf16), TextEncoding.Unicode)
            else
                Text.FromBinary(raw, TextEncoding.Unicode),

    //==================== long values (Memo / OLE, LVAL pages) ====================
    // In-row value: uint32 length (low 30 bits; top 2 bits = storage type) then a
    // 4-byte row pointer. 0x80000000 = data inline after the 12-byte header,
    // 0x40000000 = one LVAL row, 0x00000000 = chain of LVAL rows, each starting
    // with the pointer to the next.
    LongValueBytes = (defn as binary) as binary =>
        let
            lw   = U32Of(defn, 0),
            len  = Number.BitwiseAnd(lw, 1073741823),
            styp = Number.BitwiseAnd(lw, 3221225472),
            ptr  = U32Of(defn, 4)
        in
            if len = 0 then #binary({})
            else if styp = 2147483648 then Slice(defn, 12, len)
            else if styp = 1073741824 then Slice(FindPgRow(ptr), 0, len)
            else if styp = 0 then
                let
                    chunks = List.Generate(
                        () => [r = FindPgRow(ptr), p = ptr],
                        (st) => st[p] <> 0,
                        (st) => let np = U32Of(st[r], 0)
                                in  [r = if np = 0 then null else FindPgRow(np), p = np],
                        (st) => Slice(st[r], 4, Binary.Length(st[r]) - 4))
                in
                    Slice(Binary.Combine(chunks), 0, len)
            else
                error Error.Record("DataFormat.Error",
                    "Unknown long-value storage type.", [LengthWord = lw]),

    //==================== value decoding ====================
    OleDate = (v as number) as datetime =>
        // OLE Automation date: whole days since 1899-12-30; the fraction is the
        // time of day and is read as a magnitude even for negative dates.
        let days = Number.RoundTowardZero(v)
        in  #datetime(1899, 12, 30, 0, 0, 0) + #duration(days, 0, 0, Number.Abs(v - days) * 86400),

    GuidText = (raw as binary) as text =>
        let
            bl = List.Buffer(Binary.ToList(raw)),
            H  = (idxs as list) as text =>
                Text.Upper(Binary.ToText(Binary.FromList(List.Transform(idxs, (i) => bl{i})), BinaryEncoding.Hex))
        in
            "{" & H({3, 2, 1, 0}) & "-" & H({5, 4}) & "-" & H({7, 6}) & "-"
                & H({8, 9}) & "-" & H({10, 11, 12, 13, 14, 15}) & "}",

    NumericValue = (c as record, raw as binary) as number =>
        // 1 sign byte, then a 16-byte unscaled integer as four little-endian
        // 32-bit words, most significant word first. Wide values lose precision.
        let
            neg  = ByteOf(raw, 0) <> 0,
            mant = List.Accumulate({0 .. 3}, 0, (s, i) => s * 4294967296 + U32Of(raw, 1 + 4 * i)),
            v    = mant / Number.Power(10, c[Scale])
        in
            if neg then -v else v,

    DecodeValue = (c as record, raw as binary) as any =>
        let t = c[Type]
        in
            if t = 2 then ByteOf(raw, 0)                              // Byte (unsigned)
            else if t = 3 then I16Of(raw, 0)                          // Integer
            else if t = 4 then I32Of(raw, 0)                          // Long Integer
            else if t = 5 then I64Of(raw, 0) / 10000                  // Currency
            else if t = 6 then F32Fmt(raw)                            // Single
            else if t = 7 then F64Fmt(raw)                            // Double
            else if t = 8 then OleDate(F64Fmt(raw))                   // Date/Time
            else if t = 9 then raw                                    // Binary
            else if t = 10 then                                       // Text
                (if c[IsFixed] then Text.TrimEnd(DecodeText(raw), Character.FromNumber(0))
                 else DecodeText(raw))
            else if t = 11 then LongValueBytes(raw)                   // OLE Object
            else if t = 12 then DecodeText(LongValueBytes(raw))       // Memo / Long Text
            else if t = 15 then GuidText(raw)                         // Replication ID / GUID
            else if t = 16 then NumericValue(c, raw)                  // Decimal
            else if t = 18 then I32Of(raw, 0)                         // Complex (key of hidden child table)
            else if t = 19 then I64Of(raw, 0)                         // Big Integer
            else if OptStrict then
                error Error.Record("DataFormat.Error",
                    "Unsupported column type " & Number.ToText(t) & " in column """ & c[Name] & """.", null)
            else raw,

    //==================== row decoding ====================
    // Row layout: uint16 stored-column count, fixed columns (at FixedOff + 2),
    // variable columns, then from the end: null bitmap (1 bit per stored column,
    // set = not null), uint16 variable-column count, and the variable-column
    // offset table (entry i at base - 2*(i+1); entry varCount is the end-of-data
    // offset). Boolean values live in the null bitmap itself. Rows written before
    // columns were added store fewer columns; the missing ones read as null.
    CrackRow = (T as record, rowBin0 as binary) as list =>
        let
            rowBin   = Binary.Buffer(rowBin0),
            len      = Binary.Length(rowBin),
            nStored  = U16Of(rowBin, 0),
            maskLen  = Number.IntegerDivide(nStored + 7, 8),
            mask     = List.Buffer(Binary.ToList(Slice(rowBin, len - maskLen, maskLen))),
            NotNull  = (cn as number) as logical =>
                let bi = Number.IntegerDivide(cn, 8)
                in  bi < maskLen and Number.BitwiseAnd(mask{bi}, Bit{Number.Mod(cn, 8)}) <> 0,
            varBase  = len - maskLen - 2,
            varCount = if T[NumVarCols] > 0 then U16Of(rowBin, varBase) else 0,
            VarOff   = (i as number) as number => U16Of(rowBin, varBase - 2 * (i + 1))
        in
            List.Transform(T[Cols], (c) =>
                if c[Type] = 1 then NotNull(c[ColNum])                 // Yes/No: the bit is the value
                else if not NotNull(c[ColNum]) then null
                else if c[IsFixed] then DecodeValue(c, Slice(rowBin, 2 + c[FixedOff], c[Len]))
                else if c[VarIdx] >= varCount then null
                else DecodeValue(c, Slice(rowBin, VarOff(c[VarIdx]), VarOff(c[VarIdx] + 1) - VarOff(c[VarIdx])))),

    //==================== table materialization ====================
    TableDataPages = (T as record) as list =>
        let
            fromMap = UsagePages(FindPgRow(T[UsedPtr])),
            candidates =
                if fromMap <> null then fromMap
                else {1 .. Number.IntegerDivide(total, PageSize) - 1}
        in
            List.Select(candidates, (pg) =>
                PageOff(pg) + PageSize <= total
                and ByteAt(PageOff(pg)) = 1
                and U32(PageOff(pg) + 4) = T[TdefPg]),

    TableRowLists = (T as record) as list =>
        List.Combine(List.Transform(TableDataPages(T), (pg) =>
            let n = SlotCount(pg)
            in
                if n = 0 then {}
                else List.Combine(List.Transform({0 .. n - 1}, (r) =>
                    let raw = SlotRaw(pg, r)
                    in
                        if Number.BitwiseAnd(raw, 32768) <> 0 then {}   // deleted (or overflow target)
                        else if Number.BitwiseAnd(raw, 16384) <> 0 then
                            {CrackRow(T, FollowOverflow(U32(PageOff(pg) + Number.BitwiseAnd(raw, 8191))))}
                        else
                            {CrackRow(T, RowBinAt(pg, r))})))),

    MType = (t as number) as type =>
        if t = 1 then type logical
        else if t = 2 or t = 3 or t = 4 or t = 18 or t = 19 then Int64.Type
        else if t = 5 then Currency.Type
        else if t = 6 or t = 7 or t = 16 then type number
        else if t = 8 then type datetime
        else if t = 10 or t = 12 or t = 15 then type text
        else if t = 9 or t = 11 then type binary
        else type any,

    DecodeTable = (tdefPg as number) as table =>
        let
            T        = ParseTdef(tdefPg),
            names    = List.Transform(T[Cols], each [Name]),
            rows     = if OptMaxRows <> null then List.FirstN(TableRowLists(T), OptMaxRows)
                       else TableRowLists(T),
            untyped  = Table.FromRows(rows, names),
            colTypes = List.Transform(T[Cols], (c) => {c[Name], MType(c[Type])}),
            asType   = Value.Type(Table.TransformColumnTypes(#table(names, {}), colTypes))
        in
            Value.ReplaceType(untyped, asType),

    //==================== system catalog / navigation ====================
    // MSysObjects (its TDEF is always page 2) lists every object: Type 1 = local
    // table, 4/6 = linked (no local data), 5 = query. System objects carry flag
    // bits 0x80000002 and/or an MSys/~ name prefix.
    Catalog   = if HeaderOk then ParseTdef(2)
                else error Error.Record("DataFormat.Error", "Header validation failed.", null),
    CatNames  = List.Transform(Catalog[Cols], each [Name]),
    IdxOf     = (nm as text) as number =>
        let i = List.PositionOf(CatNames, nm)
        in  if i < 0
            then error Error.Record("DataFormat.Error",
                    "The system catalog (MSysObjects) has no """ & nm & """ column.", [Columns = CatNames])
            else i,
    IdxName   = IdxOf("Name"),
    IdxId     = IdxOf("Id"),
    IdxType   = IdxOf("Type"),
    IdxFlags  = IdxOf("Flags"),

    Objects = List.Transform(TableRowLists(Catalog), (r) =>
        [Name = r{IdxName}, Id = r{IdxId}, ObjType = r{IdxType},
         Flags = if r{IdxFlags} = null then 0 else r{IdxFlags}]),

    IsSystem = (o as record) as logical =>
        let fl = if o[Flags] < 0 then o[Flags] + 4294967296 else o[Flags]
        in  Number.BitwiseAnd(fl, 2147483650) <> 0               // 0x80000002
            or Text.StartsWith(o[Name], "MSys")
            or Text.StartsWith(o[Name], "~"),

    UserTables = List.Sort(
        List.Select(Objects, (o) =>
            o[ObjType] = 1 and o[Name] <> null and (OptSystem or not IsSystem(o))),
        each [Name]),

    TdefPageOf = (id as number) as number =>
        Number.Mod(if id < 0 then id + 4294967296 else id, 16777216),  // low 24 bits of Id

    NavRows = List.Transform(UserTables, (o) =>
        {o[Name], DecodeTable(TdefPageOf(o[Id])), "Table", "Table", true}),

    NavType =
        Type.AddTableKey(
            type table [Name = text, Data = any, ItemKind = text, ItemName = text, IsLeaf = logical],
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
              Access.Version      = Version,
              Access.Format       = FormatName,
              Access.CreationDate = CreationDate
          ]
in
    Nav
