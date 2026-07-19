// SPDX-License-Identifier: Apache-2.0
//
// Spss.Document.pq — read SPSS system files (.sav, .zsav) in pure Power Query M.
// No SPSS, no R, no Python interpreter, no ODBC driver, no custom connector required.
// Paste into a blank query (name it Spss.Document), or wrap as a function in your PBIX / dataflow.
//
// Usage:
//   let
//       Spss.Document = <this expression>,
//       doc  = Spss.Document(File.Contents("C:\path\to\survey.sav")),  // nav table
//       data = doc{[Name = "Data"]}[Data],
//       vars = doc{[Name = "Variables"]}[Data],
//       vals = doc{[Name = "ValueLabels"]}[Data]
//   in
//       data
//
// Options (optional second argument, all keys optional):
//   ApplyValueLabels   logical, default false — replace coded values with their value
//                      labels in the Data table (unlabeled values pass through).
//   UserMissingToNull  logical, default false — values declared user-missing in the
//                      dictionary (discrete values or ranges) become null, matching
//                      how SPSS treats them in analysis. System-missing is always null.
//   Encoding           TextEncoding or codepage number for dictionary and data text,
//                      overriding what the file declares. Files that declare nothing
//                      default to Windows-1252 (the codepage of most legacy files).
//   MaxRows            number — stop after this many cases.
//   Strict             logical, default false — when true, tolerated malformations
//                      become errors (a trailing partial case, value-label indices
//                      that point into the middle of a string, numeric data found in
//                      a string column).
//
// Supported: .sav uncompressed, .sav bytecode-compressed (the default SPSS writes),
//            and .zsav (zlib, including multi-block); numeric and string variables;
//            long variable names; very long strings (width > 255, reassembled across
//            segments); variable labels; value labels, including long-string value
//            labels; user-missing declarations (discrete and ranges); measurement
//            level, display width, alignment; DATE/DATETIME/TIME formats decoded to
//            M date/datetime/duration (SPSS epoch 1582-10-14); character encoding
//            from the file's declaration, including legacy codepage files.
// Not supported: big-endian files (written by pre-2000 UNIX SPSS — clear error);
//            EBCDIC files (clear error); case weights are reported in the metadata
//            but not applied.
// Output:    a navigation table with three rows — Data (the cases), Variables (the
//            data dictionary), ValueLabels (variable, value, label) — with
//            Spss.Product, Spss.FileLabel, Spss.CreationDate, Spss.Compression,
//            Spss.CodePage, Spss.CaseCount, Spss.WeightVariable and Spss.Documents
//            in the table metadata.

(source as binary, optional options as nullable record) as table =>
let
    bin   = Binary.Buffer(source),
    total = Binary.Length(bin),

    opts           = if options = null then [] else options,
    OptStrict      = Record.FieldOrDefault(opts, "Strict", false) = true,
    OptMaxRows     = Record.FieldOrDefault(opts, "MaxRows", null),
    OptLabels      = Record.FieldOrDefault(opts, "ApplyValueLabels", false) = true,
    OptUserMissing = Record.FieldOrDefault(opts, "UserMissingToNull", false) = true,
    OptEncoding    = Record.FieldOrDefault(opts, "Encoding", null),

    //==================== low-level byte access ====================
    Slice = (b as binary, offset as number, count as number) as binary =>
        if count <= 0 then #binary({})
        else Binary.Range(b, offset, count),

    U32Fmt = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger32, ByteOrder.LittleEndian),
    F64Fmt = BinaryFormat.ByteOrder(BinaryFormat.Double, ByteOrder.LittleEndian),

    ByteOf = (b as binary, off as number) as number => BinaryFormat.Byte(Binary.Range(b, off, 1)),
    U32Of  = (b as binary, off as number) as number => U32Fmt(Slice(b, off, 4)),
    I32Of  = (b as binary, off as number) as number =>
        let u = U32Of(b, off) in if u >= 2147483648 then u - 4294967296 else u,
    U64Of  = (b as binary, off as number) as number =>          // file offsets; < 2^53 in practice
        U32Of(b, off) + U32Of(b, off + 4) * 4294967296,
    F64Of  = (b as binary, off as number) as number => F64Fmt(Slice(b, off, 8)),

    ByteAt = (off as number) as number => ByteOf(bin, off),
    I32    = (off as number) as number => I32Of(bin, off),

    NumList = (n as number) as list => if n <= 0 then {} else {0 .. n - 1},
    RoundUpTo = (n as number, unit as number) as number =>
        unit * Number.IntegerDivide(n + unit - 1, unit),

    SpacesBin = #binary({32, 32, 32, 32, 32, 32, 32, 32}),

    //==================== file header (176 bytes) ====================
    Magic = if total >= 176 then Text.FromBinary(Slice(bin, 0, 4), TextEncoding.Ascii) else "",
    CheckMagic =
        if Magic <> "$FL2" and Magic <> "$FL3"
        then error Error.Record("DataFormat.Error",
                "Not an SPSS system file (missing ""$FL2""/""$FL3"" signature).",
                [Signature = Magic])
        else true,

    LayoutCode = I32(64),
    CheckLayout =
        if LayoutCode = 2 or LayoutCode = 3 then true
        else if LayoutCode = 33554432 or LayoutCode = 50331648     // byte-swapped 2 / 3
        then error Error.Record("DataFormat.Error",
                "This is a big-endian SPSS file (written by SPSS on a big-endian UNIX " &
                "system). Only little-endian files are supported; re-save the file " &
                "with a modern SPSS or with PSPP.", null)
        else error Error.Record("DataFormat.Error",
                "Unrecognized layout code in the file header.", [LayoutCode = LayoutCode]),

    Compression   = I32(72),
    WeightIndex   = I32(76),
    HeaderNCases  = I32(80),
    Bias          = F64Of(bin, 84),
    CheckCompression =
        if Compression >= 0 and Compression <= 2 then true
        else error Error.Record("DataFormat.Error",
                "Unknown compression code " & Number.ToText(Compression) &
                " in the file header (0, 1 and 2 are defined).", null),

    HeaderOk = CheckMagic and CheckLayout and CheckCompression,

    //==================== dictionary records ====================
    // The dictionary is a sequence of variable-length records between the header
    // and the type-999 terminator. Value-label records (type 3) are always
    // followed by the type-4 record naming the variables they apply to; the two
    // are consumed together.
    RecordAt = (pos as number) as record =>
        let rt = I32(pos)
        in
            if rt = 2 then
                let
                    vtype   = I32(pos + 4),
                    hasLab  = I32(pos + 8) <> 0,
                    nMiss   = I32(pos + 12),
                    labLen  = if hasLab then I32(pos + 32) else 0,
                    labSize = if hasLab then 4 + RoundUpTo(labLen, 4) else 0,
                    missOff = pos + 32 + labSize,
                    nm      = Number.Abs(nMiss)
                in
                    [Kind = "var", Next = missOff + 8 * nm,
                     Var = [
                        Type     = vtype,
                        NameBin  = Slice(bin, pos + 24, 8),
                        LabelBin = if hasLab then Slice(bin, pos + 36, labLen) else null,
                        NMissing = nMiss,
                        MissBins = List.Transform(NumList(nm), (i) => Slice(bin, missOff + 8 * i, 8)),
                        PrintFmt = I32(pos + 16),
                        WriteFmt = I32(pos + 20)
                     ]]
            else if rt = 3 then
                let
                    n = I32(pos + 4),
                    EntryAt = (p as number, i as number) as record =>
                        let len = ByteAt(p + 8)
                        in  [I = i, ValueBin = Slice(bin, p, 8),
                             LabelBin = Slice(bin, p + 9, len),
                             Next = p + 8 + RoundUpTo(len + 1, 8)],
                    entries = List.Generate(
                        () => if n = 0 then null else EntryAt(pos + 8, 0),
                        (e) => e <> null,
                        (e) => if e[I] + 1 >= n then null else EntryAt(e[Next], e[I] + 1)),
                    after = if n = 0 then pos + 8 else List.Last(entries)[Next],
                    check = if I32(after) <> 4
                            then error Error.Record("DataFormat.Error",
                                    "Value-label record is not followed by its variable record.",
                                    [Offset = after])
                            else true,
                    nvars = if check then I32(after + 4) else 0,
                    idxs  = List.Transform(NumList(nvars), (i) => I32(after + 8 + 4 * i))
                in
                    [Kind = "vlab", Next = after + 8 + 4 * nvars,
                     Labels = List.Transform(entries, (e) => [ValueBin = e[ValueBin], LabelBin = e[LabelBin]]),
                     Indices = idxs]
            else if rt = 6 then
                let n = I32(pos + 4)
                in  [Kind = "doc", Next = pos + 8 + 80 * n,
                     Lines = List.Transform(NumList(n), (i) => Slice(bin, pos + 8 + 80 * i, 80))]
            else if rt = 7 then
                let size = I32(pos + 8), count = I32(pos + 12)
                in  [Kind = "ext", Next = pos + 16 + size * count,
                     Subtype = I32(pos + 4), Payload = Slice(bin, pos + 16, size * count)]
            else if rt = 999 then
                [Kind = "end", Next = pos + 8]
            else
                error Error.Record("DataFormat.Error",
                    "Unknown dictionary record type " & Number.ToText(rt) & ".",
                    [Offset = pos]),

    Records = if HeaderOk then
                  List.Generate(
                      () => RecordAt(176),
                      (r) => r <> null,
                      (r) => if r[Kind] = "end" then null else RecordAt(r[Next]))
              else error Error.Record("DataFormat.Error", "Header validation failed.", null),

    DataStart = List.Last(Records)[Next],
    Slots     = List.Buffer(List.Transform(List.Select(Records, (r) => r[Kind] = "var"), (r) => r[Var])),
    ExtOf     = (subtype as number) as nullable binary =>
        let hits = List.Select(Records, (r) => r[Kind] = "ext" and r[Subtype] = subtype)
        in  if List.IsEmpty(hits) then null else hits{0}[Payload],

    //==================== machine info, encoding ====================
    Ext4   = ExtOf(4),
    SysMis = if Ext4 <> null and Binary.Length(Ext4) >= 8 then F64Of(Ext4, 0)
             else -1.7976931348623157E308,

    Ext3     = ExtOf(3),
    CharCode = if Ext3 <> null and Binary.Length(Ext3) >= 32 then I32Of(Ext3, 28) else null,
    Ext20    = ExtOf(20),
    Declared = if Ext20 = null then null
               else Text.Upper(Text.Trim(Text.FromBinary(Ext20, TextEncoding.Ascii))),

    EncFromName = (n as text) as number =>
        if n = "UTF-8" or n = "UTF8" then TextEncoding.Utf8
        else if n = "ASCII" or n = "US-ASCII" then TextEncoding.Ascii
        else if n = "ISO-8859-1" or n = "ISO8859-1" or n = "LATIN1" or n = "LATIN-1" then 28591
        else if Text.StartsWith(n, "WINDOWS-") then Number.FromText(Text.AfterDelimiter(n, "WINDOWS-"))
        else if Text.StartsWith(n, "CP") then Number.FromText(Text.Range(n, 2))
        else error Error.Record("DataFormat.Error",
                "The file declares character encoding """ & n & """, which this reader " &
                "does not recognize. Pass options[Encoding] with the matching codepage number.",
                null),
    EncFromCharCode = (c as number) as number =>
        if c = 1 then error Error.Record("DataFormat.Error",
                "This file declares EBCDIC character data, which is not supported.", null)
        else if c = 2 or c = 3 then 1252                            // "ASCII" in practice
        else if c = 4 then error Error.Record("DataFormat.Error",
                "This file declares DEC Kanji character data, which is not supported.", null)
        else c,                                                     // a Windows codepage number

    Enc = if OptEncoding <> null then OptEncoding
          else if Declared <> null then EncFromName(Declared)
          else if CharCode <> null then EncFromCharCode(CharCode)
          else 1252,

    Dec   = (b as binary) as text => if Binary.Length(b) = 0 then "" else Text.FromBinary(b, Enc),
    TrimR = (t as text) as text => Text.TrimEnd(t, {" ", Character.FromNumber(0)}),

    //==================== variables (merge continuation slots) ====================
    // A string of width w occupies ceil(w / 8) consecutive 8-byte case elements;
    // its dictionary entry is one type-w record followed by type -1 continuations.
    ElemsOf = (w as number) as number =>
        if w = 0 then 1 else Number.IntegerDivide(w + 7, 8),

    Vars0 = List.Generate(
        () => [I = 0],
        (s) => s[I] < List.Count(Slots),
        (s) => [I = s[I] + ElemsOf(Slots{s[I]}[Type])],
        (s) =>
            let
                v = Slots{s[I]},
                w = v[Type],
                e = ElemsOf(w),
                checkNotCont =
                    if w = -1
                    then error Error.Record("DataFormat.Error",
                            "String-continuation record found where a variable was expected " &
                            "(the dictionary is inconsistent).", [Slot = s[I]])
                    else true,
                checkConts =
                    if List.Count(List.Select(NumList(e - 1), (k) => Slots{s[I] + 1 + k}[Type] <> -1)) > 0
                    then error Error.Record("DataFormat.Error",
                            "Missing string-continuation record (the dictionary is inconsistent).",
                            [Slot = s[I]])
                    else true
            in
                if checkNotCont and checkConts then
                    [Slot = s[I], Short = TrimR(Dec(v[NameBin])), Width = w, Elements = e,
                     LabelBin = v[LabelBin], NMissing = v[NMissing], MissBins = v[MissBins],
                     PrintFmt = v[PrintFmt], WriteFmt = v[WriteFmt],
                     Segments = {[W = w, E = e]}]
                else []),

    //==================== ext 13: long variable names ====================
    Ext13 = ExtOf(13),
    LongNames =
        if Ext13 = null then []
        else Record.Combine(List.Transform(
                 List.Select(Text.Split(Dec(Ext13), Character.FromNumber(9)),
                             (p) => Text.Contains(p, "=")),
                 (p) => Record.FromList({TrimR(Text.AfterDelimiter(p, "="))},
                                        {Text.Trim(TrimR(Text.BeforeDelimiter(p, "=")))}))),
    NameOfShort = (short as text) as text => Record.FieldOrDefault(LongNames, short, short),

    //==================== ext 14: very long strings ====================
    // A string wider than 255 is stored as ceil(w / 252) dictionary variables
    // ("segments"): all but the last declared width 255, the last w - 252*(n-1).
    // Case data is packed 255 bytes per segment; leftover allocated space is
    // ignored (PSPP spec). This record maps first-segment short name -> true width.
    Ext14 = ExtOf(14),
    VlsWidths =
        if Ext14 = null then []
        else Record.Combine(List.Transform(
                 List.Select(Text.Split(Text.Replace(Dec(Ext14), Character.FromNumber(0), ""),
                                        Character.FromNumber(9)),
                             (p) => Text.Contains(p, "=")),
                 (p) => Record.FromList({Number.FromText(Text.AfterDelimiter(p, "="))},
                                        {Text.Trim(Text.BeforeDelimiter(p, "="))}))),

    Vars1 = List.Buffer(Vars0),
    Vars2 = List.Generate(
        () => [I = 0],
        (s) => s[I] < List.Count(Vars1),
        (s) =>
            let tw = Record.FieldOrDefault(VlsWidths, Vars1{s[I]}[Short], 0)
            in  [I = s[I] + (if tw > 255 then Number.IntegerDivide(tw + 251, 252) else 1)],
        (s) =>
            let
                v  = Vars1{s[I]},
                tw = Record.FieldOrDefault(VlsWidths, v[Short], 0)
            in
                if tw <= 255 then v
                else
                    let
                        nseg = Number.IntegerDivide(tw + 251, 252),
                        segs = List.Transform(NumList(nseg), (k) =>
                                   let sv = Vars1{s[I] + k} in [W = sv[Width], E = sv[Elements]])
                    in
                        v & [Width = tw,
                             Elements = List.Sum(List.Transform(segs, (g) => g[E])),
                             Segments = segs]),

    //==================== ext 11: measure / display width / alignment ====================
    // One int32 triple per pre-merge variable; a merged very long string had one
    // triple per segment — the first applies, the rest are skipped.
    Ext11 = ExtOf(11),
    Triples = if Ext11 = null then {}
              else List.Split(List.Transform(NumList(Number.IntegerDivide(Binary.Length(Ext11), 4)),
                                             (i) => I32Of(Ext11, 4 * i)), 3),
    MeasureName = (m as number) as nullable text =>
        if m = 1 then "Nominal" else if m = 2 then "Ordinal" else if m = 3 then "Scale" else null,
    AlignName = (a as number) as nullable text =>
        if a = 0 then "Left" else if a = 1 then "Right" else if a = 2 then "Center" else null,

    Vars3 = List.Accumulate(Vars2, [TI = 0, Out = {}], (st, v) =>
        [TI  = st[TI] + List.Count(v[Segments]),
         Out = st[Out] & {v & (
                   if st[TI] < List.Count(Triples) then
                       let t = Triples{st[TI]}
                       in  [Measure = MeasureName(t{0}), DisplayWidth = t{1}, Alignment = AlignName(t{2})]
                   else [Measure = null, DisplayWidth = null, Alignment = null])}])[Out],

    //==================== finalize variables ====================
    NElements =
        if List.IsEmpty(Vars3)
        then error Error.Record("DataFormat.Error",
                "The dictionary declares no variables.", null)
        else List.Sum(List.Transform(Vars3, (v) => v[Elements])),

    MissingSpecOf = (v as record) as nullable record =>
        // negative NMissing: first two values are a range, any further value is discrete
        if v[NMissing] = 0 then null
        else if v[Width] = 0 then
            let nums = List.Transform(v[MissBins], (b) => F64Of(b, 0))
            in  if v[NMissing] < 0
                then [Lo = nums{0}, Hi = nums{1}, Values = List.Skip(nums, 2)]
                else [Lo = null, Hi = null, Values = nums]
        else [Lo = null, Hi = null, Values = List.Transform(v[MissBins], (b) => TrimR(Dec(b)))],

    MissingText = (spec as nullable record) as nullable text =>
        if spec = null then null
        else Text.Combine(
                 (if spec[Lo] <> null
                  then {Text.From(spec[Lo]) & " THRU " & Text.From(spec[Hi])} else {})
                 & List.Transform(spec[Values], (x) => Text.From(x)),
                 "; "),

    Vars = List.Buffer(List.Accumulate(Vars3, [E = 0, P = 0, Out = {}], (st, v) =>
        [E = st[E] + v[Elements], P = st[P] + 1,
         Out = st[Out] & {v & [
             Name     = NameOfShort(v[Short]),
             Label    = if v[LabelBin] = null then null else TrimR(Dec(v[LabelBin])),
             Start    = st[E],
             Position = st[P] + 1,
             Missing  = MissingSpecOf(v)
         ]}])[Out]),

    VarBySlot = (slot as number) as nullable record =>
        let hits = List.Select(Vars, (v) => v[Slot] = slot)
        in  if List.IsEmpty(hits) then null else hits{0},

    //==================== formats ====================
    // print/write format: 0x00TTWWDD — type, width, decimals. The width byte
    // cannot hold a very long string's width, so string formats use the true one.
    FormatNames = {"", "A", "AHEX", "COMMA", "DOLLAR", "F", "IB", "PIBHEX", "P", "PIB",
                   "PK", "RB", "RBHEX", "", "", "Z", "N", "E", "", "",
                   "DATE", "TIME", "DATETIME", "ADATE", "JDATE", "DTIME", "WKDAY", "MONTH",
                   "MOYR", "QYR", "WKYR", "PCT", "DOT", "CCA", "CCB", "CCC", "CCD", "CCE",
                   "EDATE", "SDATE", "MTIME", "YMDHMS"},
    FmtType = (packed as number) as number => Number.IntegerDivide(packed, 65536),
    FmtText = (packed as number, trueWidth as number) as text =>
        let
            t = FmtType(packed),
            w0 = Number.Mod(Number.IntegerDivide(packed, 256), 256),
            w = if trueWidth > w0 then trueWidth else w0,
            d = Number.Mod(packed, 256),
            nm = if t >= 0 and t < List.Count(FormatNames) then FormatNames{t} else "",
            nm2 = if nm = "" then "?" & Number.ToText(t) else nm
        in
            nm2 & Number.ToText(w) & (if d > 0 then "." & Number.ToText(d) else ""),

    IsDateFmt     = (t as number) as logical =>
        t = 20 or t = 23 or t = 24 or t = 28 or t = 29 or t = 30 or t = 38 or t = 39,
    IsDateTimeFmt = (t as number) as logical => t = 22 or t = 41,
    IsTimeFmt     = (t as number) as logical => t = 21 or t = 25 or t = 40,

    Epoch = #datetime(1582, 10, 14, 0, 0, 0),                      // SPSS day zero, seconds

    ConvertNumeric = (v as record, x as nullable number) as any =>
        let t = FmtType(v[PrintFmt])
        in
            if x = null then null
            else if IsDateFmt(t) then DateTime.Date(Epoch + #duration(0, 0, 0, x))
            else if IsDateTimeFmt(t) then Epoch + #duration(0, 0, 0, x)
            else if IsTimeFmt(t) then #duration(0, 0, 0, x)
            else x,

    ColumnType = (v as record) as type =>
        let t = FmtType(v[PrintFmt])
        in
            if v[Width] > 0 then type text
            else if IsDateFmt(t) then type date
            else if IsDateTimeFmt(t) then type datetime
            else if IsTimeFmt(t) then type duration
            else type number,

    //==================== value labels ====================
    VLabSets = List.Select(Records, (r) => r[Kind] = "vlab"),
    ShortLabelRows = List.Combine(List.Transform(VLabSets, (set) =>
        List.Combine(List.Transform(set[Indices], (idx) =>
            let v = VarBySlot(idx - 1)
            in
                if v = null then
                    if OptStrict
                    then error Error.Record("DataFormat.Error",
                            "Value-label variable index does not point at a variable.",
                            [Index = idx])
                    else {}
                else
                    List.Transform(set[Labels], (lb) =>
                        {v[Name],
                         if v[Width] = 0 then F64Of(lb[ValueBin], 0) else TrimR(Dec(lb[ValueBin])),
                         Dec(lb[LabelBin])}))))),

    // ext 21: value labels for strings wider than 8 bytes, keyed by long name
    Ext21 = ExtOf(21),
    LongLabelRows =
        if Ext21 = null then {}
        else
            let
                len = Binary.Length(Ext21),
                Walk = (p as number, acc as list) as list =>
                    if p >= len then acc
                    else
                        let
                            nlen  = I32Of(Ext21, p),
                            vname = Dec(Slice(Ext21, p + 4, nlen)),
                            nlab  = I32Of(Ext21, p + 4 + nlen + 4),
                            Inner = (q as number, k as number, acc2 as list) as record =>
                                if k >= nlab then [Pos = q, Rows = acc2]
                                else
                                    let
                                        vlen = I32Of(Ext21, q),
                                        val  = TrimR(Dec(Slice(Ext21, q + 4, vlen))),
                                        llen = I32Of(Ext21, q + 4 + vlen),
                                        lab  = Dec(Slice(Ext21, q + 8 + vlen, llen))
                                    in
                                        @Inner(q + 8 + vlen + llen, k + 1, acc2 & {{vname, val, lab}}),
                            done = Inner(p + 4 + nlen + 8, 0, {})
                        in
                            @Walk(done[Pos], acc & done[Rows])
            in
                Walk(0, {}),

    ValueLabelRows = ShortLabelRows & LongLabelRows,

    //==================== case data: element tokens ====================
    // A case is NElements 8-byte elements. Tokens: a number (already-decoded
    // bytecode value), an 8-byte binary, or null (system-missing).
    TokensUncompressed = (buf as binary, cap as nullable number) as list =>
        let
            avail = Number.IntegerDivide(Binary.Length(buf), 8),
            n     = if cap <> null and cap < avail then cap else avail
        in
            if n = 0 then {} else BinaryFormat.List(BinaryFormat.Binary(8), n)(buf),

    // Bytecode (compression 1, also inside zsav): 8 command bytes, then one
    // 8-byte literal per 253 among them. 0 pad, 1..251 value = code - bias,
    // 252 end of data, 253 literal follows, 254 eight spaces, 255 sysmis.
    TokensBytecode = (buf as binary) as list =>
        let
            len = Binary.Length(buf),
            ChunkAt = (p as number) as record =>
                let
                    st = List.Accumulate(Binary.ToList(Slice(buf, p, 8)),
                            [T = {}, L = 0, D = false],
                            (st, c) =>
                                if st[D] then st
                                else if c = 0 then st
                                else if c = 252 then st & [D = true]
                                else if c = 253 then
                                    [T = st[T] & {Slice(buf, p + 8 + 8 * st[L], 8)},
                                     L = st[L] + 1, D = false]
                                else if c = 254 then st & [T = st[T] & {SpacesBin}]
                                else if c = 255 then st & [T = st[T] & {null}]
                                else st & [T = st[T] & {c - Bias}])
                in
                    [Tokens = st[T], Next = p + 8 + 8 * st[L], Done = st[D]],
            chunks = List.Generate(
                () => if len < 8 then null else ChunkAt(0),
                (c) => c <> null,
                (c) => if c[Done] or c[Next] + 8 > len then null else ChunkAt(c[Next]))
        in
            List.Combine(List.Transform(chunks, (c) => c[Tokens])),

    // zsav: a 24-byte header, zlib blocks, and a trailer of block descriptors.
    // Each block is a zlib stream: 2-byte header stripped, trailing Adler-32
    // ignored by the Deflate decoder. The decompressed stream is bytecode.
    ZsavStream = () as binary =>
        let
            ztrailerOfs = U64Of(bin, DataStart + 8),
            nBlocks     = I32Of(bin, ztrailerOfs + 20),
            blocks = List.Transform(NumList(nBlocks), (k) =>
                let
                    d     = ztrailerOfs + 24 + 24 * k,
                    cOfs  = U64Of(bin, d + 8),
                    uSize = I32Of(bin, d + 16),
                    cSize = I32Of(bin, d + 20),
                    raw   = Binary.Buffer(Binary.Decompress(
                                Slice(bin, cOfs + 2, cSize - 2), Compression.Deflate))
                in
                    if Binary.Length(raw) <> uSize
                    then error Error.Record("DataFormat.Error",
                            "A zsav data block did not decompress to its declared size.",
                            [Block = k, Expected = uSize, Actual = Binary.Length(raw)])
                    else raw)
        in
            Binary.Combine(blocks),

    DataBin = Binary.Buffer(Slice(bin, DataStart, total - DataStart)),
    AllTokens = List.Buffer(
        if Compression = 0 then
            TokensUncompressed(DataBin,
                if HeaderNCases >= 0 then HeaderNCases * NElements else null)
        else if Compression = 1 then TokensBytecode(DataBin)
        else TokensBytecode(Binary.Buffer(ZsavStream()))),

    //==================== cases ====================
    FullCases  = Number.IntegerDivide(List.Count(AllTokens), NElements),
    CheckTail  =
        if OptStrict and Number.Mod(List.Count(AllTokens), NElements) <> 0
        then error Error.Record("DataFormat.Error",
                "The case data ends with a partial case.",
                [Elements = List.Count(AllTokens), PerCase = NElements])
        else true,
    NCases0 = if CheckTail then
                  (if HeaderNCases >= 0 and HeaderNCases < FullCases then HeaderNCases else FullCases)
              else 0,
    NCases  = if OptMaxRows <> null and OptMaxRows < NCases0 then OptMaxRows else NCases0,

    Cases = List.FirstN(List.Split(AllTokens, NElements), NCases),

    NumTok = (t) as nullable number =>
        if t = null then null
        else
            let x = if t is number then t else F64Of(t, 0)
            in  if x = SysMis then null else x,
    BytesTok = (t) as binary =>
        if t = null then SpacesBin
        else if t is number then
            (if OptStrict
             then error Error.Record("DataFormat.Error",
                     "Compressed numeric data found inside a string value.", null)
             else SpacesBin)
        else t,

    IsUserMissing = (v as record, x) as logical =>
        let m = v[Missing]
        in
            m <> null and
            (List.Contains(m[Values], x)
             or (m[Lo] <> null and x >= m[Lo] and x <= m[Hi])),

    LabelMaps = List.Buffer(List.Transform(Vars, (v) =>
        let mine = List.Select(ValueLabelRows, (r) => r{0} = v[Name])
        in
            if List.IsEmpty(mine) then null
            else Record.Combine(List.Transform(mine, (r) =>
                     Record.FromList({r{2}}, {Text.From(r{1})}))))),

    CellOf = (v as record, mapIdx as number, caseToks as list) as any =>
        let
            raw =
                if v[Width] = 0 then NumTok(caseToks{v[Start]})
                else
                    let
                        joined = Binary.Combine(
                            List.Accumulate(v[Segments], [Off = v[Start], Parts = {}], (st, g) =>
                                let
                                    segBytes = Binary.Combine(List.Transform(NumList(g[E]),
                                                   (k) => BytesTok(caseToks{st[Off] + k}))),
                                    take = if 8 * g[E] > 255 then 255 else 8 * g[E]
                                in
                                    [Off = st[Off] + g[E],
                                     Parts = st[Parts] & {Slice(segBytes, 0, take)}])[Parts]),
                        cut = if Binary.Length(joined) > v[Width]
                              then Slice(joined, 0, v[Width]) else joined
                    in
                        TrimR(Dec(cut)),
            lm = LabelMaps{mapIdx}
        in
            if raw = null then null
            else if OptUserMissing and IsUserMissing(v, raw) then null
            else if OptLabels and lm <> null then
                Record.FieldOrDefault(lm, Text.From(raw),
                    if v[Width] = 0 then ConvertNumeric(v, raw) else raw)
            else if v[Width] = 0 then ConvertNumeric(v, raw)
            else raw,

    ColNames = List.Transform(Vars, (v) => v[Name]),
    DataRows = List.Transform(Cases, (c) =>
        let toks = List.Buffer(c)
        in  List.Transform(List.Positions(Vars), (i) => CellOf(Vars{i}, i, toks))),

    BaseTable = #table(ColNames, DataRows),
    // labeled columns hold a mix of label text and pass-through values when
    // ApplyValueLabels is on, so they are left untyped
    TypePairs = List.Combine(List.Transform(List.Positions(Vars), (i) =>
        if OptLabels and LabelMaps{i} <> null then {}
        else {{Vars{i}[Name], ColumnType(Vars{i})}})),
    DataTable = Table.TransformColumnTypes(BaseTable, TypePairs),

    //==================== Variables and ValueLabels tables ====================
    VariablesTable = Table.TransformColumnTypes(
        #table({"Position", "Name", "Label", "Type", "Width", "PrintFormat", "WriteFormat",
                "Measure", "DisplayWidth", "Alignment", "MissingValues"},
               List.Transform(Vars, (v) =>
                   {v[Position], v[Name], v[Label],
                    if v[Width] = 0 then "Numeric" else "String",
                    v[Width],
                    FmtText(v[PrintFmt], v[Width]),
                    FmtText(v[WriteFmt], v[Width]),
                    v[Measure], v[DisplayWidth], v[Alignment],
                    MissingText(v[Missing])})),
        {{"Position", Int64.Type}, {"Name", type text}, {"Label", type text},
         {"Type", type text}, {"Width", Int64.Type}, {"PrintFormat", type text},
         {"WriteFormat", type text}, {"Measure", type text}, {"DisplayWidth", Int64.Type},
         {"Alignment", type text}, {"MissingValues", type text}}),

    ValueLabelsTable = Table.TransformColumnTypes(
        #table({"Variable", "Value", "Label"}, ValueLabelRows),
        {{"Variable", type text}, {"Label", type text}}),

    //==================== navigation table ====================
    Documents = List.Combine(List.Transform(
        List.Select(Records, (r) => r[Kind] = "doc"),
        (r) => List.Transform(r[Lines], (l) => TrimR(Dec(l))))),

    WeightVar = if WeightIndex > 0 then
                    let v = VarBySlot(WeightIndex - 1)
                    in  if v = null then null else v[Name]
                else null,

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
              #table({"Name", "Data", "ItemKind", "ItemName", "IsLeaf"},
                     {{"Data", DataTable, "Table", "Table", true},
                      {"Variables", VariablesTable, "Table", "Table", true},
                      {"ValueLabels", ValueLabelsTable, "Table", "Table", true}}),
              NavType)
          meta [
              Spss.Product        = TrimR(Text.FromBinary(Slice(bin, 4, 60), Enc)),
              Spss.FileLabel      = TrimR(Text.FromBinary(Slice(bin, 109, 64), Enc)),
              Spss.CreationDate   = Text.FromBinary(Slice(bin, 92, 9), TextEncoding.Ascii) & " " &
                                    Text.FromBinary(Slice(bin, 101, 8), TextEncoding.Ascii),
              Spss.Compression    = if Compression = 0 then "None"
                                    else if Compression = 1 then "Bytecode"
                                    else "ZLIB (zsav)",
              Spss.CodePage       = Enc,
              Spss.CaseCount      = NCases0,
              Spss.WeightVariable = WeightVar,
              Spss.Documents      = Documents
          ]
in
    Nav
