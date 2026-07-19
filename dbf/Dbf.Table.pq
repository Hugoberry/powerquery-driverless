// SPDX-License-Identifier: Apache-2.0
//
// Dbf.Table.pq: read dBASE / FoxPro tables (.dbf) in pure Power Query M.
// No Visual FoxPro OLE DB driver, no ODBC, no custom connector required.
// Paste into a blank query (name it Dbf.Table), or wrap as a function in your PBIX / dataflow.
//
// Usage:
//   let
//       Dbf.Table = <this expression>,
//       t = Dbf.Table(File.Contents("C:\path\to\table.dbf"))
//   in
//       t
//
//   // Tables with memo fields (M, and FoxPro G/P/W) keep the memo text in a
//   // sidecar file (.fpt for FoxPro, .dbt for dBASE). Pass it as a second binary:
//   //   Dbf.Table(File.Contents("...\table.dbf"), [Memo = File.Contents("...\table.fpt")])
//   // Without it, memo columns come back as nulls (an error when Strict = true).
//
// Options (optional second argument, all keys optional):
//   Memo            binary: the .fpt / .dbt memo sidecar file.
//   Encoding        codepage number or TextEncoding value, overriding the
//                   file's language-driver byte (files that declare nothing
//                   default to 1252).
//   IncludeDeleted  logical, default false: keep records flagged as deleted
//                   and append a _Deleted logical column.
//   MaxRows         number: stop after this many rows.
//   Strict          logical, default false: when true, malformed input that
//                   is normally tolerated becomes an error (bad numerics,
//                   dates or logicals; truncated record area; field lengths
//                   that disagree with the header; memo pointers with no
//                   Memo sidecar provided).
//
// Supported: dBASE III/IV/5 (0x03, 0x83, 0x8B and friends), FoxBASE (0x02,
//            0xFB), FoxPro 2.x (0xF5) and Visual FoxPro (0x30/0x31/0x32);
//            field types C N F D L M I B Y T V Q G P W and '+', including
//            VFP null flags, Varchar/Varbinary lengths, Char fields wider
//            than 255 bytes and comma decimal separators; dBASE III
//            (0x1A-terminated), dBASE IV (length-prefixed) and FoxPro
//            (typed, block-sized) memo sidecars; deleted-record flags;
//            language-driver codepages.
// Not supported: dBASE Level 7 (0x04/0x8C, a different header layout; clear
//            error); encrypted tables; index sidecars (.mdx/.cdx are never
//            needed to read the data).
// Precision: currency (Y) is a scaled 64-bit integer and M numbers are
//            doubles, so more than 15 significant digits lose precision.
// Output:    a table, one column per field, typed; header facts are attached
//            as metadata (Dbf.Version, Dbf.Dialect, Dbf.Codepage,
//            Dbf.LastUpdate, Dbf.RecordCount).

(source as binary, optional options as nullable record) as table =>
let
    bin   = Binary.Buffer(source),
    total = Binary.Length(bin),

    opts              = if options = null then [] else options,
    OptStrict         = Record.FieldOrDefault(opts, "Strict", false) = true,
    OptMaxRows        = Record.FieldOrDefault(opts, "MaxRows", null),
    OptIncludeDeleted = Record.FieldOrDefault(opts, "IncludeDeleted", false) = true,
    OptEncoding       = Record.FieldOrDefault(opts, "Encoding", null),
    MemoBin           = let m = Record.FieldOrDefault(opts, "Memo", null)
                        in  if m = null then null else Binary.Buffer(m),

    //==================== low-level byte access ====================
    Slice = (b as binary, offset as number, count as number) as binary =>
        if count <= 0 then #binary({})
        else Binary.Range(b, offset, count),

    Byte = (off as number) as number => BinaryFormat.Byte(Binary.Range(bin, off, 1)),

    U16Fmt   = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger16, ByteOrder.LittleEndian),
    U32Fmt   = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger32, ByteOrder.LittleEndian),
    I32Fmt   = BinaryFormat.ByteOrder(BinaryFormat.SignedInteger32,   ByteOrder.LittleEndian),
    I64Fmt   = BinaryFormat.ByteOrder(BinaryFormat.SignedInteger64,   ByteOrder.LittleEndian),
    U16BEFmt = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger16, ByteOrder.BigEndian),
    U32BEFmt = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger32, ByteOrder.BigEndian),

    UIntLEOf = (b as binary) as number =>             // little-endian unsigned
        let n = Binary.Length(b)
        in  if n = 2 then U16Fmt(b)
            else if n = 4 then U32Fmt(b)
            else List.Accumulate(Binary.ToList(b), [v = 0, s = 1],
                     (st, c) => [v = st[v] + c * st[s], s = st[s] * 256])[v],
    IntLEOf = (b as binary) as number =>              // two's complement
        let n = Binary.Length(b)
        in  if n = 0 then 0
            else if n = 4 then I32Fmt(b)
            else if n = 8 then I64Fmt(b)
            else let u = UIntLEOf(b)
                 in  if u >= Number.Power(2, 8 * n - 1) then u - Number.Power(2, 8 * n)
                     else u,
    UIntBEOf = (b as binary) as number =>
        let n = Binary.Length(b)
        in  if n = 2 then U16BEFmt(b)
            else if n = 4 then U32BEFmt(b)
            else List.Accumulate(Binary.ToList(b), 0, (s, c) => s * 256 + c),
    DoubleOf = BinaryFormat.ByteOrder(BinaryFormat.Double, ByteOrder.LittleEndian),
    NulChar  = Character.FromNumber(0),

    //==================== header ====================
    FoxproVersions     = {0x30, 0x31, 0x32, 0xF5},    // .fpt sidecar
    VfpVersions        = {0x30, 0x31, 0x32},          // B = double, 4-byte memo ptr
    Dbase4MemoVersions = {0x8B, 0x8E, 0xCB},          // .dbt, length-prefixed
    KnownVersions      = {0x02, 0x03, 0x43, 0x63, 0x83, 0x8B, 0x8E, 0xCB, 0xFB}
                         & FoxproVersions,

    Version =
        if total < 32 then
            error Error.Record("DataFormat.Error",
                "File is shorter than the 32-byte dBASE header.",
                [FileSize = total])
        else if Byte(0) = 0x04 or Byte(0) = 0x8C then
            error Error.Record("DataFormat.Error",
                "dBASE Level 7 files use a different header layout and are not supported.",
                [VersionByte = Byte(0)])
        else if not List.Contains(KnownVersions, Byte(0)) then
            error Error.Record("DataFormat.Error",
                "Not a dBASE/FoxPro table (unrecognised version byte).",
                [VersionByte = Byte(0)])
        else Byte(0),

    DialectNames = {
        {0x02, "FoxBASE"},                {0x03, "dBASE III"},
        {0x30, "Visual FoxPro"},          {0x31, "Visual FoxPro (autoincrement)"},
        {0x32, "Visual FoxPro (Varchar)"},{0x43, "dBASE IV SQL"},
        {0x63, "dBASE IV SQL system"},    {0x83, "dBASE III (memo)"},
        {0x8B, "dBASE IV (memo)"},        {0x8E, "dBASE IV SQL (memo)"},
        {0xCB, "dBASE IV SQL (memo)"},    {0xF5, "FoxPro 2.x (memo)"},
        {0xFB, "FoxBASE (memo)"}},
    Dialect = List.First(List.Transform(
                  List.Select(DialectNames, each _{0} = Version), each _{1})),

    RecordCount = UIntLEOf(Slice(bin, 4, 4)),
    HeaderSize0 = UIntLEOf(Slice(bin, 8, 2)),
    RecordSize  = UIntLEOf(Slice(bin, 10, 2)),
    LangDriver  = Byte(29),

    HeaderSize =
        if Version >= 0 and (HeaderSize0 < 65 or HeaderSize0 > total or RecordSize < 1) then
            error Error.Record("DataFormat.Error",
                "Header sizes are implausible.",
                [HeaderSize = HeaderSize0, RecordSize = RecordSize, FileSize = total])
        else HeaderSize0,

    // Language driver byte -> codepage, per the xBase language driver table.
    CodepageMap = {
        {0x01, 437},  {0x02, 850},  {0x03, 1252}, {0x04, 10000}, {0x08, 865},
        {0x09, 437},  {0x0A, 850},  {0x0B, 437},  {0x0D, 437},   {0x0E, 850},
        {0x0F, 437},  {0x10, 850},  {0x11, 437},  {0x12, 850},   {0x13, 932},
        {0x14, 850},  {0x15, 437},  {0x16, 850},  {0x17, 865},   {0x18, 437},
        {0x19, 437},  {0x1A, 850},  {0x1B, 437},  {0x1C, 863},   {0x1D, 850},
        {0x1F, 852},  {0x22, 852},  {0x23, 852},  {0x24, 860},   {0x25, 850},
        {0x26, 866},  {0x37, 850},  {0x40, 852},  {0x4D, 936},   {0x4E, 949},
        {0x4F, 950},  {0x50, 874},  {0x57, 1252}, {0x58, 1252},  {0x59, 1252},
        {0x64, 852},  {0x65, 866},  {0x66, 865},  {0x67, 861},   {0x6A, 737},
        {0x6B, 857},  {0x6C, 863},  {0x78, 950},  {0x79, 949},   {0x7A, 936},
        {0x7B, 932},  {0x7C, 874},  {0x7D, 1255}, {0x7E, 1256},  {0x86, 737},
        {0x87, 852},  {0x88, 857},  {0xC8, 1250}, {0xC9, 1251},  {0xCA, 1254},
        {0xCB, 1253}, {0xCC, 1257}},
    LangCodepage = List.First(List.Transform(
                       List.Select(CodepageMap, each _{0} = LangDriver), each _{1}),
                       1252),
    Codepage = if OptEncoding <> null then OptEncoding else LangCodepage,

    //==================== field descriptor array ====================
    // 32 bytes per field from offset 32, terminated by a 0x0D byte.
    DescrOffsets = List.Generate(
        () => 32,
        (o) => o + 32 <= HeaderSize and Byte(o) <> 0x0D,
        (o) => o + 32),
    TermOff = 32 + List.Count(DescrOffsets) * 32,
    ParseDescr = (off as number) as record =>
        let nameBytes = List.FirstN(Binary.ToList(Slice(bin, off, 11)), each _ <> 0),
            ftype     = Character.FromNumber(Byte(off + 11)),
            length0   = Byte(off + 16),
            decimals0 = Byte(off + 17),
            // dialect trick: a Char field wider than 255 keeps the high
            // byte of its length in the decimal-count byte
            wide      = ftype = "C" and decimals0 > 0
        in  [Name     = Text.FromBinary(Binary.FromList(nameBytes), Codepage),
             Type     = ftype,
             Length   = if wide then length0 + decimals0 * 256 else length0,
             Decimals = if wide then 0 else decimals0,
             Flags    = Byte(off + 18)],
    RawFields =
        if TermOff < total and Byte(TermOff) = 0x0D
        then List.Transform(DescrOffsets, ParseDescr)
        else error Error.Record("DataFormat.Error",
                 "Field descriptor array has no 0x0D terminator.",
                 [ScannedUpTo = TermOff]),

    // Record offsets (byte 0 is the deletion flag) and _NullFlags bits,
    // both allocated in field order. A Varchar/Varbinary (V/Q) field first
    // takes a varlength bit (0 = full, 1 = actual length in the field's
    // last byte); a nullable field (flag 0x02) then takes a null bit.
    Layout = List.Accumulate(RawFields, [Fields = {}, Off = 1, Bit = 0],
        (st, f) =>
            let isVQ     = f[Type] = "V" or f[Type] = "Q",
                nullable = Number.BitwiseAnd(f[Flags], 0x02) = 0x02,
                bitAfterV = if isVQ then st[Bit] + 1 else st[Bit]
            in  [Fields = st[Fields] & {f & [
                     Offset    = st[Off],
                     VarLenBit = if isVQ then st[Bit] else null,
                     NullBit   = if nullable then bitAfterV else null]},
                 Off = st[Off] + f[Length],
                 Bit = if nullable then bitAfterV + 1 else bitAfterV]),
    Fields = Layout[Fields],

    NullFlagsField = List.First(List.Select(Fields,
        each [Type] = "0" or Text.Upper([Name]) = "_NULLFLAGS"), null),
    VisibleFields = List.Select(Fields,
        each [Type] <> "0" and Number.BitwiseAnd([Flags], 0x01) = 0),

    //==================== memo sidecar ====================
    IsFpt      = List.Contains(FoxproVersions, Version),
    IsDb4Memo  = List.Contains(Dbase4MemoVersions, Version),
    MemoTotal  = if MemoBin = null then 0 else Binary.Length(MemoBin),
    MemoBlock  =
        if MemoBin = null or not IsFpt then 512
        else if MemoTotal < 8 then
            error Error.Record("DataFormat.Error",
                "Memo file is shorter than its 8-byte header.", [Size = MemoTotal])
        else
            let bs = UIntBEOf(Slice(MemoBin, 6, 2))
            in  if bs = 0 then
                    error Error.Record("DataFormat.Error",
                        "Memo file declares block size 0.", null)
                else bs,
    MemoBytes = List.Buffer(Binary.ToList(MemoBin)),  // dBASE III terminator scan

    MemoLookup = (ptr as nullable number, wantText as logical) as any =>
        if ptr = null or ptr <= 0 then null
        else if MemoBin = null then
            if OptStrict then
                error Error.Record("DataFormat.Error",
                    "The table has memo fields, but no memo sidecar was provided. " &
                    "Pass the .fpt/.dbt file as options[Memo].", [Pointer = ptr])
            else null
        else
            let start = ptr * MemoBlock
            in
                if IsFpt then
                    let hd  = if start + 8 > MemoTotal then
                                  error Error.Record("DataFormat.Error",
                                      "Memo pointer is beyond the memo file.",
                                      [Pointer = ptr, Offset = start, MemoSize = MemoTotal])
                              else [Type = UIntBEOf(Slice(MemoBin, start, 4)),
                                    Len  = UIntBEOf(Slice(MemoBin, start + 4, 4))],
                        raw = if start + 8 + hd[Len] > MemoTotal then
                                  error Error.Record("DataFormat.Error",
                                      "Memo entry is truncated.",
                                      [Pointer = ptr, Length = hd[Len], MemoSize = MemoTotal])
                              else Slice(MemoBin, start + 8, hd[Len])
                    in  if hd[Type] = 1 and wantText
                        then Text.FromBinary(raw, Codepage)
                        else raw
                else
                    let sig = start + 4 <= MemoTotal and
                              UIntLEOf(Slice(MemoBin, start, 4)) = 0x0008FFFF,
                        raw =
                            if IsDb4Memo and sig then
                                // dBASE IV: FF FF 08 00, then a little-endian
                                // length that includes the 8-byte entry header
                                let len = UIntLEOf(Slice(MemoBin, start + 4, 4))
                                in  Slice(MemoBin, start + 8,
                                          List.Min({len, MemoTotal - start}) - 8)
                            else
                                // dBASE III: text runs to the first 0x1A
                                let p = List.PositionOf(List.Skip(MemoBytes, start), 0x1A)
                                in  Slice(MemoBin, start,
                                          (if p = -1 then MemoTotal - start else p))
                    in  if wantText
                        then Text.TrimEnd(Text.FromBinary(raw, Codepage),
                                          {Character.FromNumber(0x1A), Character.FromNumber(0x1F)})
                        else raw,

    //==================== field decoding ====================
    // Julian day number -> days after 0001-01-01 (M's earliest date)
    JulianOffset = 1721425,

    ParseNumberText = (t as text) as nullable number =>
        Number.FromText(Text.Replace(t, ",", "."), "en-US"),

    Cell = (f as record, rec as binary, bitSet as function) as any =>
        let t    = f[Type],
            raw0 = Slice(rec, f[Offset], f[Length]),
            // Varchar/Varbinary: varlength bit set = last byte holds the length
            raw  = if (t = "V" or t = "Q") and bitSet(f[VarLenBit])
                   then let bytes = Binary.ToList(raw0)
                        in  Slice(raw0, 0, bytes{f[Length] - 1})
                   else raw0
        in
            if t = "C" then
                Text.TrimEnd(Text.FromBinary(raw, Codepage), {" ", NulChar})
            else if t = "V" then
                Text.FromBinary(raw, Codepage)
            else if t = "Q" then
                raw
            else if t = "N" or t = "F" then
                let txt = Text.Trim(Text.FromBinary(raw, 1252), {" ", "*", NulChar})
                in  if txt = "" or txt = "." then null
                    else let n = try ParseNumberText(txt)
                         in  if not n[HasError] then n[Value]
                             else if OptStrict then
                                 error Error.Record("DataFormat.Error",
                                     "Bad numeric value.", [Field = f[Name], Value = txt])
                             else null
            else if t = "D" then
                let txt = Text.FromBinary(raw, 1252)
                in  if Text.Trim(txt, {" ", "0", NulChar}) = "" then null
                    else let d = try #date(Number.FromText(Text.Range(txt, 0, 4), "en-US"),
                                           Number.FromText(Text.Range(txt, 4, 2), "en-US"),
                                           Number.FromText(Text.Range(txt, 6, 2), "en-US"))
                         in  if not d[HasError] then d[Value]
                             else if OptStrict then
                                 error Error.Record("DataFormat.Error",
                                     "Bad date value.", [Field = f[Name], Value = txt])
                             else null
            else if t = "L" then
                let c = Text.FromBinary(raw, 1252)
                in  if c = "T" or c = "t" or c = "Y" or c = "y" then true
                    else if c = "F" or c = "f" or c = "N" or c = "n" then false
                    else if OptStrict and not (c = "?" or c = " " or c = NulChar) then
                        error Error.Record("DataFormat.Error",
                            "Bad logical value.", [Field = f[Name], Value = c])
                    else null
            else if t = "I" or t = "+" then
                IntLEOf(raw)
            else if t = "B" and List.Contains(VfpVersions, Version) then
                DoubleOf(raw)
            else if t = "Y" then
                IntLEOf(raw) / 10000
            else if t = "T" then
                let bytes = Binary.ToList(raw)
                in  if List.MatchesAll(bytes, each _ = 0 or _ = 32) then null
                    else let day  = UIntLEOf(Slice(raw, 0, 4)),
                             msec = UIntLEOf(Slice(raw, 4, 4))
                         in  if day = 0 then null
                             else #datetime(1, 1, 1, 0, 0, 0)
                                  + #duration(day - JulianOffset - 1, 0, 0, msec / 1000)
            else if t = "M" or t = "G" or t = "P" or t = "W" or t = "B" then
                let ptr = if f[Length] = 4 then IntLEOf(raw)
                          else let txt = Text.Trim(Text.FromBinary(raw, 1252), {" ", NulChar})
                               in  if txt = "" then 0
                                   else ParseNumberText(txt),
                    wantText = t = "M" and Number.BitwiseAnd(f[Flags], 0x04) = 0
                in  MemoLookup(ptr, wantText)
            else
                error Error.Record("DataFormat.Error",
                    "Unsupported field type.", [Field = f[Name], Type = t]),

    //==================== records ====================
    Available = Number.IntegerDivide(total - HeaderSize, RecordSize),
    RowCount =
        if OptStrict and Layout[Off] <> RecordSize then
            error Error.Record("DataFormat.Error",
                "Field lengths disagree with the header's record size.",
                [SumOfFieldLengths = Layout[Off], RecordSize = RecordSize])
        else if Available >= RecordCount then RecordCount
        else if OptStrict then
            error Error.Record("DataFormat.Error",
                "The header declares more records than fit in the file.",
                [Declared = RecordCount, Available = Available])
        else Available,

    RecAt   = (i as number) as binary => Slice(bin, HeaderSize + i * RecordSize, RecordSize),
    RecFlag = (rec as binary) as number => Binary.ToList(Slice(rec, 0, 1)){0},

    AllRecs   = List.Transform(List.Numbers(0, RowCount), RecAt),
    UntilEof  = List.FirstN(AllRecs, each RecFlag(_) <> 0x1A),
    Kept      = if OptIncludeDeleted then UntilEof
                else List.Select(UntilEof, each RecFlag(_) <> 0x2A),
    Limited   = if OptMaxRows = null then Kept else List.FirstN(Kept, OptMaxRows),

    DecodeRecord = (rec as binary) as list =>
        let nfBytes = if NullFlagsField = null then {}
                      else Binary.ToList(Slice(rec, NullFlagsField[Offset],
                                               NullFlagsField[Length])),
            bitSet  = (bit as nullable number) as logical =>
                bit <> null and
                Number.IntegerDivide(bit, 8) < List.Count(nfBytes) and
                Number.BitwiseAnd(Number.BitwiseShiftRight(
                    nfBytes{Number.IntegerDivide(bit, 8)}, Number.Mod(bit, 8)), 1) = 1,
            vals    = List.Transform(VisibleFields,
                (f) => if bitSet(f[NullBit]) then null else Cell(f, rec, bitSet))
        in  vals & (if OptIncludeDeleted then {RecFlag(rec) = 0x2A} else {}),

    //==================== table shaping ====================
    ColumnNames = List.Transform(VisibleFields, each [Name])
                  & (if OptIncludeDeleted then {"_Deleted"} else {}),
    BaseTable   = #table(ColumnNames, List.Transform(Limited, DecodeRecord)),

    TypeFor = (f as record) as type =>
        let t = f[Type]
        in  if t = "C" or t = "V" then type nullable text
            else if t = "Q" or t = "G" or t = "P" or t = "W" then type nullable binary
            else if t = "N" then (if f[Decimals] = 0 then Int64.Type else type nullable number)
            else if t = "F" then type nullable number
            else if t = "B" then (if List.Contains(VfpVersions, Version)
                                  then type nullable number else type nullable binary)
            else if t = "Y" then Currency.Type
            else if t = "D" then type nullable date
            else if t = "T" then type nullable datetime
            else if t = "L" then type nullable logical
            else if t = "I" or t = "+" then Int64.Type
            else if t = "M" then (if Number.BitwiseAnd(f[Flags], 0x04) = 0
                                  then type nullable text else type nullable binary)
            else type any,
    TypePairs = List.Transform(VisibleFields, (f) => {f[Name], TypeFor(f)})
                & (if OptIncludeDeleted then {{"_Deleted", type logical}} else {}),
    Typed     = Table.TransformColumnTypes(BaseTable, TypePairs),

    LastUpdate = try #date(1900 + Byte(1), Byte(2), Byte(3)) otherwise null
in
    Typed meta [
        Dbf.Version     = Version,
        Dbf.Dialect     = Dialect,
        Dbf.Codepage    = Codepage,
        Dbf.LastUpdate  = LastUpdate,
        Dbf.RecordCount = RecordCount
    ]
