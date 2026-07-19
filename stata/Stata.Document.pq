// SPDX-License-Identifier: Apache-2.0
//
// Stata.Document.pq — read Stata datasets (.dta) in pure Power Query M.
// No Stata, no R, no Python interpreter, no ODBC driver, no custom connector required.
// Paste into a blank query (name it Stata.Document), or wrap as a function in your PBIX / dataflow.
//
// Usage:
//   let
//       Stata.Document = <this expression>,
//       doc  = Stata.Document(File.Contents("C:\path\to\survey.dta")),  // nav table
//       data = doc{[Name = "Data"]}[Data],
//       vars = doc{[Name = "Variables"]}[Data],
//       vals = doc{[Name = "ValueLabels"]}[Data]
//   in
//       data
//
// Options (optional second argument, all keys optional):
//   ApplyValueLabels       logical, default false — replace coded values with their
//                          value labels in the Data table (unlabeled values pass
//                          through; a labeled extended missing shows its label).
//   ExtendedMissingToText  logical, default false — the extended missing codes
//                          .a-.z become the texts ".a"-".z" instead of null.
//                          System missing (.) is always null.
//   Encoding               TextEncoding or codepage number for all text, overriding
//                          the default: UTF-8 for formats 118/119, Windows-1252
//                          for the older ASCII-era formats.
//   MaxRows                number — stop after this many observations.
//   Strict                 logical, default false — when true, tolerated
//                          malformations become errors (a strL pointer with no
//                          backing GSO, a truncated value-label trailer).
//
// Supported: .dta formats 113, 114, 115 (Stata 8-12), 117 (Stata 13), 118
//            (Stata 14-19) and 119 (Stata 15-19, >32,767 variables); both byte
//            orders (LSF and MSF); all five numeric storage types with the
//            Stata missing codes (., .a-.z encoded at the top of each numeric
//            range); str# and strL variables, including cross-linked, empty
//            and binary GSOs; value labels, including labels on extended
//            missing codes; variable labels; dataset label and timestamp;
//            sort order; %td/%tc/%tC/%tm/%tq/%th/%tw date formats decoded to
//            M date/datetime (Stata epoch 1960-01-01); characteristics and
//            expansion fields are skipped structurally.
// Not supported: formats written by Stata 7 or older (clear error); formats
//            120/121 (alias variables, Stata 18+ — clear error); %tC values
//            are decoded like %tc, i.e. leap seconds are not subtracted;
//            %tb business-calendar and %ty year values stay numeric.
// Output:    a navigation table with three rows — Data (the observations),
//            Variables (the data dictionary), ValueLabels (variable, value,
//            label) — with Stata.Release, Stata.ByteOrder, Stata.DatasetLabel,
//            Stata.Timestamp, Stata.ObservationCount, Stata.VariableCount,
//            Stata.SortedBy and Stata.Encoding in the table metadata.

(source as binary, optional options as nullable record) as table =>
let
    bin   = Binary.Buffer(source),
    total = Binary.Length(bin),

    opts        = if options = null then [] else options,
    OptStrict   = Record.FieldOrDefault(opts, "Strict", false) = true,
    OptMaxRows  = Record.FieldOrDefault(opts, "MaxRows", null),
    OptLabels   = Record.FieldOrDefault(opts, "ApplyValueLabels", false) = true,
    OptMissText = Record.FieldOrDefault(opts, "ExtendedMissingToText", false) = true,
    OptEncoding = Record.FieldOrDefault(opts, "Encoding", null),

    //==================== low-level byte access ====================
    Slice = (b as binary, offset as number, count as number) as binary =>
        if count <= 0 then #binary({})
        else if offset = 0 then BinaryFormat.Binary(count)(b)
        else BinaryFormat.Record([
                Skip = BinaryFormat.Binary(offset),
                Data = BinaryFormat.Binary(count)
             ])(b)[Data],

    ByteAt  = (off as number) as number => Binary.ToList(Slice(bin, off, 1)){0},
    NumList = (n as number) as list => if n <= 0 then {} else {0 .. n - 1},

    Ascii = (off as number, count as number) as text =>
        if count <= 0 then ""
        else Text.FromBinary(Slice(bin, off, count), TextEncoding.Ascii),

    // a \0-terminated string inside a fixed-width field, returned as binary
    CStrBin = (b as binary, off as number, width as number) as binary =>
        let
            bytes = Binary.ToList(Slice(b, off, width)),
            z     = List.PositionOf(bytes, 0),
            n     = if z = -1 then width else z
        in
            #binary(List.FirstN(bytes, n)),

    //==================== release detection ====================
    IsTagged = total >= 11 and Ascii(0, 11) = "<stata_dta>",
    Release =
        if IsTagged then
            if Ascii(11, 17) = "<header><release>"
            then Number.FromText(Ascii(28, 3))
            else error Error.Record("DataFormat.Error",
                    "Malformed .dta header (release marker not found).", null)
        else if total >= 109 then ByteAt(0)
        else error Error.Record("DataFormat.Error",
                "Not a Stata .dta file (too short).", null),

    CheckRelease =
        if List.Contains({113, 114, 115, 117, 118, 119}, Release) then true
        else if Release = 120 or Release = 121
        then error Error.Record("DataFormat.Error",
                "This dataset uses .dta format " & Number.ToText(Release) &
                ", written for alias variables (Stata 18+). Re-save it without " &
                "alias variables to get a supported format.", null)
        else if Release >= 102 and Release <= 112
        then error Error.Record("DataFormat.Error",
                "This dataset was written by Stata 7 or older (format " &
                Number.ToText(Release) & "). Re-save it with a newer Stata " &
                "or with another tool to get a supported format.", null)
        else error Error.Record("DataFormat.Error",
                "Not a Stata .dta file (unrecognized format).",
                [Release = Release]),

    // per-release field widths (from the published StataCorp specs)
    WVarname  = if Release >= 118 then 129 else 33,
    WFmt      = if Release >= 118 then 57 else if Release = 113 then 12 else 49,
    WLblname  = if Release >= 118 then 129 else 33,
    WVarlabel = if Release >= 118 then 321 else 81,
    WSort     = if Release = 119 then 4 else 2,
    WK        = if Release = 119 then 4 else 2,
    WN        = if Release = 117 then 4 else 8,
    WLabelLen = if Release = 117 then 1 else 2,
    WVoV      = if Release = 117 then 4 else if Release = 119 then 3 else 2,
    WGsoO     = if Release = 117 then 4 else 8,

    //==================== byte order ====================
    IsLSF =
        if CheckRelease then
            if IsTagged then
                let t = Ascii(41, 14)
                in
                    if t = "<byteorder>LSF" then true
                    else if t = "<byteorder>MSF" then false
                    else error Error.Record("DataFormat.Error",
                            "Malformed .dta header (byteorder marker not found).", null)
            else
                let b = ByteAt(1)
                in
                    if b = 2 then true
                    else if b = 1 then false
                    else error Error.Record("DataFormat.Error",
                            "Unrecognized byte-order code in the header.",
                            [Code = b])
        else false,

    BO = if IsLSF then ByteOrder.LittleEndian else ByteOrder.BigEndian,

    U16Fmt = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger16, BO),
    U32Fmt = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger32, BO),
    U64Fmt = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger64, BO),
    I16Fmt = BinaryFormat.ByteOrder(BinaryFormat.SignedInteger16, BO),
    I32Fmt = BinaryFormat.ByteOrder(BinaryFormat.SignedInteger32, BO),
    F32Fmt = BinaryFormat.ByteOrder(BinaryFormat.Single, BO),
    F64Fmt = BinaryFormat.ByteOrder(BinaryFormat.Double, BO),

    U16 = (off as number) as number => U16Fmt(Slice(bin, off, 2)),
    U32 = (off as number) as number => U32Fmt(Slice(bin, off, 4)),
    U64 = (off as number) as number => U64Fmt(Slice(bin, off, 8)),   // < 2^53 in practice
    I32 = (off as number) as number => I32Fmt(Slice(bin, off, 4)),
    // an unsigned integer of 1..8 bytes, per byte order
    UIntOf = (b as binary, off as number, size as number) as number =>
        let
            bytes = Binary.ToList(Slice(b, off, size)),
            ord   = if IsLSF then List.Reverse(bytes) else bytes
        in
            List.Accumulate(ord, 0, (s, c) => s * 256 + c),
    UIntAt = (off as number, size as number) as number => UIntOf(bin, off, size),

    //==================== character encoding ====================
    Enc = if OptEncoding <> null then OptEncoding
          else if Release >= 118 then TextEncoding.Utf8
          else 1252,
    Dec = (b as binary) as text =>
        if Binary.Length(b) = 0 then "" else Text.FromBinary(b, Enc),
    CStr = (b as binary, off as number, width as number) as text =>
        Dec(CStrBin(b, off, width)),

    //==================== header ====================
    // Tagged formats (117+): "<stata_dta><header><release>NNN</release>
    // <byteorder>XXX</byteorder><K>..</K><N>..</N><label>..</label>
    // <timestamp>..</timestamp></header><map>..." — the markers are required,
    // in this order, run together. Legacy formats (113-115) use a fixed
    // 109-byte header.
    KOff  = 70,                                                     // after "<K>"
    NOff  = KOff + WK + 4 + 3,                                      // "</K><N>"
    LabOff = NOff + WN + 4 + 7,                                     // "</N><label>"

    NVar = if IsTagged then UIntAt(KOff, WK) else U16(4),
    NObs = if IsTagged then UIntAt(NOff, WN) else U32(6),

    LabelLen  = if IsTagged then UIntAt(LabOff, WLabelLen) else null,
    DataLabel = if IsTagged then Dec(Slice(bin, LabOff + WLabelLen, LabelLen))
                else CStr(bin, 10, 81),
    TsOff     = if IsTagged then LabOff + WLabelLen + LabelLen + 8 + 11 else null,
    TsLen     = if IsTagged then ByteAt(TsOff) else null,
    Timestamp = if IsTagged then Ascii(TsOff + 1, TsLen)
                else Text.FromBinary(CStrBin(bin, 91, 18), TextEncoding.Ascii),

    //==================== section offsets ====================
    // Tagged: the <map> holds 14 8-byte offsets to every section marker.
    MapOff =
        if not IsTagged then null
        else
            let p = TsOff + 1 + TsLen
            in
                if Ascii(p, 26) = "</timestamp></header><map>" then p + 26
                else error Error.Record("DataFormat.Error",
                        "Malformed .dta header (map marker not found).", null),
    MapAt = (i as number) as number => U64(MapOff + 8 * i),

    VerifyTag = (off as number, tagText as text) as number =>
        if Ascii(off, Text.Length(tagText)) = tagText
        then off + Text.Length(tagText)
        else error Error.Record("DataFormat.Error",
                "Malformed .dta file (expected " & tagText & " marker).",
                [Offset = off]),

    TypesOff    = if IsTagged then VerifyTag(MapAt(2), "<variable_types>")
                  else 109,
    NamesOff    = if IsTagged then VerifyTag(MapAt(3), "<varnames>")
                  else TypesOff + NVar,
    SortOff     = if IsTagged then VerifyTag(MapAt(4), "<sortlist>")
                  else NamesOff + WVarname * NVar,
    FmtsOff     = if IsTagged then VerifyTag(MapAt(5), "<formats>")
                  else SortOff + 2 * (NVar + 1),
    LblNamesOff = if IsTagged then VerifyTag(MapAt(6), "<value_label_names>")
                  else FmtsOff + WFmt * NVar,
    VarLabsOff  = if IsTagged then VerifyTag(MapAt(7), "<variable_labels>")
                  else LblNamesOff + WLblname * NVar,

    // Legacy: expansion fields sit between the variable labels and the data;
    // each has a 1-byte type and 4-byte length, terminated by type 0 len 0.
    SkipExpansion = (p as number) as number =>
        let dt = ByteAt(p), ln = U32(p + 1)
        in  if dt = 0 and ln = 0 then p + 5 else @SkipExpansion(p + 5 + ln),

    DataOff    = if IsTagged then VerifyTag(MapAt(9), "<data>")
                 else SkipExpansion(VarLabsOff + WVarlabel * NVar),
    StrlsOff   = if IsTagged then VerifyTag(MapAt(10), "<strls>") else null,
    ValLabsOff = if IsTagged then VerifyTag(MapAt(11), "<value_labels>") else null,

    //==================== variables ====================
    TypeCodeAt = (i as number) as number =>
        if IsTagged then U16(TypesOff + 2 * i) else ByteAt(TypesOff + i),

    KindOf = (t as number) as record =>
        if IsTagged then
            if t = 32768 then [Kind = "strL", Width = 8]
            else if t >= 1 and t <= 2045 then [Kind = "str", Width = t]
            else if t = 65526 then [Kind = "double", Width = 8]
            else if t = 65527 then [Kind = "float", Width = 4]
            else if t = 65528 then [Kind = "long", Width = 4]
            else if t = 65529 then [Kind = "int", Width = 2]
            else if t = 65530 then [Kind = "byte", Width = 1]
            else error Error.Record("DataFormat.Error",
                    "Unknown variable type code " & Number.ToText(t) & ".", null)
        else
            if t = 251 then [Kind = "byte", Width = 1]
            else if t = 252 then [Kind = "int", Width = 2]
            else if t = 253 then [Kind = "long", Width = 4]
            else if t = 254 then [Kind = "float", Width = 4]
            else if t = 255 then [Kind = "double", Width = 8]
            else if t >= 1 and t <= 244 then [Kind = "str", Width = t]
            else error Error.Record("DataFormat.Error",
                    "Unknown variable type code " & Number.ToText(t) & ".", null),

    // %fmt classification: %td (and old %d) days, %tc/%tC milliseconds,
    // %tm months, %tq quarters, %th half-years, %tw weeks — all since
    // 1960-01-01. %ty and business calendars (%tb) stay numeric.
    FmtKindOf = (fmt as text) as nullable text =>
        let
            f1 = if Text.StartsWith(fmt, "%") then Text.Range(fmt, 1) else fmt,
            f  = if Text.StartsWith(f1, "-") then Text.Range(f1, 1) else f1
        in
            if Text.StartsWith(f, "d") then "td"
            else if not Text.StartsWith(f, "t") or Text.Length(f) < 2 then null
            else
                let c = Text.Range(f, 1, 1)
                in
                    if c = "c" or c = "C" then "tc"
                    else if List.Contains({"d", "w", "m", "q", "h"}, c) then "t" & c
                    else null,

    Vars0 = List.Transform(NumList(NVar), (i) =>
        let
            k   = KindOf(TypeCodeAt(i)),
            fmt = CStr(bin, FmtsOff + WFmt * i, WFmt)
        in
            [
                Position = i + 1,
                Name     = CStr(bin, NamesOff + WVarname * i, WVarname),
                Kind     = k[Kind],
                Width    = k[Width],
                Format   = fmt,
                FmtKind  = if k[Kind] = "str" or k[Kind] = "strL" then null
                           else FmtKindOf(fmt),
                LabelSet = let s = CStr(bin, LblNamesOff + WLblname * i, WLblname)
                           in  if s = "" then null else s,
                Label    = let s = CStr(bin, VarLabsOff + WVarlabel * i, WVarlabel)
                           in  if s = "" then null else s
            ]),
    Vars = List.Buffer(List.Accumulate(Vars0, [Off = 0, Out = {}], (st, v) =>
        [Off = st[Off] + v[Width],
         Out = st[Out] & {v & [Offset = st[Off]]}])[Out]),
    RowSize = List.Sum(List.Transform(Vars, (v) => v[Width])),

    CheckVars =
        if NVar = 0
        then error Error.Record("DataFormat.Error",
                "The dataset declares no variables.", null)
        else true,

    //==================== sort order ====================
    SortBy = List.Generate(
        () => [I = 0, V = if NVar = 0 then 0 else UIntAt(SortOff, WSort)],
        (s) => s[V] <> 0 and s[I] < NVar,
        (s) => [I = s[I] + 1, V = UIntAt(SortOff + WSort * (s[I] + 1), WSort)],
        (s) => Vars{s[V] - 1}[Name]),

    //==================== strLs (GSO table) ====================
    HasStrL = List.MatchesAny(Vars, (v) => v[Kind] = "strL"),
    GsoList =
        if not (IsTagged and HasStrL) then {}
        else List.Generate(
            () => StrlsOff,
            (p) => Ascii(p, 3) = "GSO",
            (p) => p + 12 + WGsoO + U32(p + 8 + WGsoO),
            (p) =>
                let
                    v   = U32(p + 3),
                    o   = UIntAt(p + 7, WGsoO),
                    t   = ByteAt(p + 7 + WGsoO),
                    len = U32(p + 8 + WGsoO),
                    c   = Slice(bin, p + 12 + WGsoO, len)
                in
                    [Key = Number.ToText(v) & ":" & Number.ToText(o),
                     IsBinary = t = 129,
                     Value = if t = 129 then c
                             else Dec(CStrBin(c, 0, len))]),
    GsoMap = Record.FromList(List.Transform(GsoList, (g) => g[Value]),
                             List.Transform(GsoList, (g) => g[Key])),
    HasBinaryGso = List.MatchesAny(GsoList, (g) => g[IsBinary]),

    //==================== value labels ====================
    MissNames = List.Buffer({"."} & List.Transform({0 .. 25},
        (i) => "." & Character.FromNumber(97 + i))),

    // int32 label keys at the top of the long range are extended missings
    LabelKeyOf = (val as number) as any =>
        if val > 2147483620 then MissNames{val - 2147483621} else val,

    // one <lbl> / trailer block: len, labname, 3 pad bytes, then the table
    // (n, txtlen, off[n], val[n], txt) — all per byte order
    LabelSetAt = (p as number) as record =>
        let
            len     = U32(p),
            name    = CStr(bin, p + 4, WLblname),
            t       = p + 4 + WLblname + 3,
            n       = U32(t),
            txtlen  = U32(t + 4),
            txtOff  = t + 8 + 8 * n,
            entries = List.Transform(NumList(n), (i) =>
                let
                    off = U32(t + 8 + 4 * i),
                    val = I32(t + 8 + 4 * n + 4 * i)
                in
                    [Key   = val,
                     Label = CStr(bin, txtOff + off, txtlen - off)])
        in
            [Name = name, Entries = entries, Next = p + 4 + WLblname + 3 + len],

    LabelSets =
        if IsTagged then
            List.Generate(
                () => if Ascii(ValLabsOff, 5) = "<lbl>" then LabelSetAt(ValLabsOff + 5) else null,
                (s) => s <> null,
                (s) => if Ascii(s[Next] + 6, 5) = "<lbl>"                // skip "</lbl>"
                       then LabelSetAt(s[Next] + 6 + 5) else null)
        else
            List.Generate(
                () => let p0 = DataOff + RowSize * NObs
                      in  if p0 + 4 + WLblname + 3 <= total then LabelSetAt(p0) else null,
                (s) => s <> null,
                (s) => if s[Next] + 4 + WLblname + 3 <= total
                       then LabelSetAt(s[Next])
                       else if OptStrict and s[Next] < total
                       then error Error.Record("DataFormat.Error",
                               "Truncated value-label record at the end of the file.",
                               [Offset = s[Next]])
                       else null),

    // set name -> record of label texts keyed by value (missings as ".a" etc.)
    SetMaps = Record.FromList(
        List.Transform(LabelSets, (s) =>
            Record.FromList(
                List.Transform(s[Entries], (e) => e[Label]),
                List.Transform(s[Entries], (e) => Text.From(LabelKeyOf(e[Key]))))),
        List.Transform(LabelSets, (s) => s[Name])),

    LabelMaps = List.Buffer(List.Transform(Vars, (v) =>
        if v[LabelSet] = null then null
        else Record.FieldOrDefault(SetMaps, v[LabelSet], null))),

    //==================== observations ====================
    NObs0 = if CheckVars then NObs else 0,
    CheckSize =
        if DataOff + RowSize * NObs0 > total
        then error Error.Record("DataFormat.Error",
                "The file is shorter than its declared number of observations requires.",
                [Expected = DataOff + RowSize * NObs0, Actual = total])
        else true,
    NRows = if CheckSize then
                (if OptMaxRows <> null and OptMaxRows < NObs0 then OptMaxRows else NObs0)
            else 0,

    // missing codes: integers above the per-type maximum, floats at or above
    // 2^127 (steps of 2^115), doubles at or above 2^1023 (steps of 2^1011);
    // index 0 is "." (system missing), 1-26 are .a-.z
    FloatCut   = Number.Power(2, 127),
    FloatStep  = Number.Power(2, 115),
    DoubleCut  = Number.Power(2, 1023),
    DoubleStep = Number.Power(2, 1011),

    MissIndexOf = (kind as text, x as number) as nullable number =>
        if kind = "byte" then (if x <= 100 then null else x - 101)
        else if kind = "int" then (if x <= 32740 then null else x - 32741)
        else if kind = "long" then (if x <= 2147483620 then null else x - 2147483621)
        else if Number.IsNaN(x) or x = Number.PositiveInfinity
                or x = Number.NegativeInfinity then 0
        else if kind = "float" then
            (if x < FloatCut then null
             else List.Min({Number.RoundDown((x - FloatCut) / FloatStep + 0.5), 26}))
        else
            (if x < DoubleCut then null
             else List.Min({Number.RoundDown((x - DoubleCut) / DoubleStep + 0.5), 26})),

    EpochDate = #date(1960, 1, 1),
    EpochDT   = #datetime(1960, 1, 1, 0, 0, 0),

    ConvertDatish = (fk as nullable text, x as number) as any =>
        if fk = null then x
        else if fk = "td" then Date.AddDays(EpochDate, Number.RoundDown(x))
        else if fk = "tc" then EpochDT + #duration(0, 0, 0, x / 1000)
        else if fk = "tm" then Date.AddMonths(EpochDate, Number.RoundDown(x))
        else if fk = "tq" then Date.AddMonths(EpochDate, 3 * Number.RoundDown(x))
        else if fk = "th" then Date.AddMonths(EpochDate, 6 * Number.RoundDown(x))
        else                                                        // tw
            let w = Number.RoundDown(x)
            in  Date.AddDays(Date.AddYears(EpochDate, Number.IntegerDivide(w, 52)),
                             7 * Number.Mod(w, 52)),

    ReadVo = (rowBin as binary, off as number) as text =>
        Number.ToText(UIntOf(rowBin, off, WVoV)) & ":" &
        Number.ToText(UIntOf(rowBin, off + WVoV, 8 - WVoV)),

    CellOf = (v as record, mapIdx as number, rowBin as binary) as any =>
        let off = v[Offset], k = v[Kind]
        in
            if k = "str" then Dec(CStrBin(rowBin, off, v[Width]))
            else if k = "strL" then
                let key = ReadVo(rowBin, off)
                in
                    if key = "0:0" then ""
                    else Record.FieldOrDefault(GsoMap, key,
                            if OptStrict
                            then error Error.Record("DataFormat.Error",
                                    "A strL value points at a GSO that is not " &
                                    "defined in the file.", [Pointer = key])
                            else null)
            else
                let
                    x  = if k = "byte" then
                             let b = Binary.ToList(Slice(rowBin, off, 1)){0}
                             in  if b > 127 then b - 256 else b
                         else if k = "int" then I16Fmt(Slice(rowBin, off, 2))
                         else if k = "long" then I32Fmt(Slice(rowBin, off, 4))
                         else if k = "float" then F32Fmt(Slice(rowBin, off, 4))
                         else F64Fmt(Slice(rowBin, off, 8)),
                    mi = MissIndexOf(k, x),
                    lm = LabelMaps{mapIdx},
                    labeled =
                        if lm = null or not OptLabels then null
                        else Record.FieldOrDefault(lm,
                                if mi = null then Text.From(x) else MissNames{mi},
                                null)
                in
                    if labeled <> null then labeled
                    else if mi = null then ConvertDatish(v[FmtKind], x)
                    else if mi > 0 and OptMissText then MissNames{mi}
                    else null,

    ColNames = List.Transform(Vars, (v) => v[Name]),
    // one sequential pass slices the fixed-width observations; cells are
    // then read inside their own small row binary
    RowBins = if NRows = 0 then {}
              else BinaryFormat.List(BinaryFormat.Binary(RowSize), NRows)(
                       Slice(bin, DataOff, RowSize * NRows)),
    DataRows = List.Transform(RowBins, (rowBin) =>
        List.Transform(List.Positions(Vars), (i) => CellOf(Vars{i}, i, rowBin))),

    //==================== the Data table ====================
    ColumnType = (v as record) as type =>
        let k = v[Kind]
        in
            if k = "str" or k = "strL" then type text
            else if v[FmtKind] = "tc" then type datetime
            else if v[FmtKind] <> null then type date
            else if k = "float" or k = "double" then type number
            else Int64.Type,

    BaseTable = #table(ColNames, DataRows),
    // labeled columns mix label text with pass-through values when
    // ApplyValueLabels is on; ExtendedMissingToText mixes ".a" texts into
    // numeric columns; a strL column can hold binary GSOs — all are left
    // untyped
    TypePairs = List.Combine(List.Transform(List.Positions(Vars), (i) =>
        let v = Vars{i}
        in
            if (OptLabels and LabelMaps{i} <> null)
               or (OptMissText and v[Kind] <> "str" and v[Kind] <> "strL")
               or (v[Kind] = "strL" and HasBinaryGso)
            then {}
            else {{v[Name], ColumnType(v)}})),
    DataTable = Table.TransformColumnTypes(BaseTable, TypePairs),

    //==================== Variables and ValueLabels tables ====================
    TypeName = (v as record) as text =>
        if v[Kind] = "str" then "str" & Number.ToText(v[Width]) else v[Kind],

    VariablesTable = Table.TransformColumnTypes(
        #table({"Position", "Name", "Label", "Type", "Format", "ValueLabelSet"},
               List.Transform(Vars, (v) =>
                   {v[Position], v[Name], v[Label], TypeName(v), v[Format],
                    v[LabelSet]})),
        {{"Position", Int64.Type}, {"Name", type text}, {"Label", type text},
         {"Type", type text}, {"Format", type text}, {"ValueLabelSet", type text}}),

    ValueLabelRows = List.Combine(List.Transform(Vars, (v) =>
        if v[LabelSet] = null then {}
        else
            let hits = List.Select(LabelSets, (s) => s[Name] = v[LabelSet])
            in
                if List.IsEmpty(hits) then {}                       // name never defined
                else List.Transform(hits{0}[Entries], (e) =>
                         {v[Name], LabelKeyOf(e[Key]), e[Label]}))),
    ValueLabelsTable = Table.TransformColumnTypes(
        #table({"Variable", "Value", "Label"}, ValueLabelRows),
        {{"Variable", type text}, {"Label", type text}}),

    //==================== navigation table ====================
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
              Stata.Release          = Release,
              Stata.ByteOrder        = if IsLSF then "LSF" else "MSF",
              Stata.DatasetLabel     = if DataLabel = "" then null else DataLabel,
              Stata.Timestamp        = if Timestamp = "" then null else Timestamp,
              Stata.ObservationCount = NObs0,
              Stata.VariableCount    = NVar,
              Stata.SortedBy         = SortBy,
              Stata.Encoding         = Enc
          ]
in
    Nav
