// SPDX-License-Identifier: Apache-2.0
//
// Xls.Workbook.pq — read legacy Excel workbooks (.xls, BIFF8) in pure Power Query M.
// No ACE OLEDB provider, no gateway software, no custom connector required.
// Paste into a blank query (name it Xls.Workbook), or wrap as a function in your PBIX / dataflow.
//
// Usage:
//   let
//       Xls.Workbook = <this expression>,
//       wb    = Xls.Workbook(File.Contents("C:\path\to\file.xls")),  // nav table of sheets
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
//                        become errors (shared-string index out of range, inline
//                        strings truncated at a record boundary).
//
// Supported: BIFF8 (Excel 97-2003) workbooks in their CFB container, including
//            streams stored in the mini-stream; SST shared strings across CONTINUE
//            records (strings split mid-text restart with a fresh flags byte);
//            RK, MULRK, NUMBER, LABELSST, LABEL, RSTRING, BOOLERR, BLANK, MULBLANK
//            and FORMULA (cached number/string/boolean/error results); hidden
//            sheets; date/time detection from builtin and custom number formats;
//            the 1904 date system.
// Not supported: BIFF5/BIFF7 (Excel 5.0/95 — clear error); encrypted or
//            password-protected workbooks (clear error); chart sheets and macro
//            sheets (skipped); inline LABEL strings that span a CONTINUE record
//            (truncated unless Strict = true); live formula evaluation (the
//            cached result is returned); pivot caches, comments, shapes (ignored).
// Precision: Excel serial numbers are IEEE doubles and convert to datetime at
//            sub-millisecond precision. Serials 1..59 use the 1899-12-31 epoch so
//            displayed dates match Excel (Lotus leap-year bug); the fictitious
//            1900-02-29 (serial 60) becomes 1900-03-01.
// Output:    a navigation table (Name, Data, Hidden, ItemKind, ItemName, IsLeaf)
//            of the worksheets, with Xls.Date1904 in the table metadata.

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
    Hex = (b as binary) as text => Text.Upper(Binary.ToText(b, BinaryEncoding.Hex)),

    // BIFF8 "compressed" characters are the low bytes of UTF-16, i.e. Latin-1
    // (not Windows-1252 — bytes 0x80-0x9F map to U+0080-U+009F)
    Latin1 = (b as binary) as text =>
        Text.Combine(List.Transform(Binary.ToList(b), Character.FromNumber)),

    //==================== CFB container ====================
    FREESECT = 0xFFFFFFFF,
    ENDCHAIN = 0xFFFFFFFE,

    MagicOk = total >= 512 and Hex(Slice(bin, 0, 8)) = "D0CF11E0A1B11AE1",
    MagicCheck =
        if MagicOk then true
        else if total >= 4 and Hex(Slice(bin, 0, 4)) = "504B0304" then
            error Error.Record("DataFormat.Error",
                "This is a ZIP-based workbook (.xlsx or .xlsb), not a legacy .xls. " &
                "Use Excel.Workbook or Xlsb.Workbook instead.", null)
        else
            error Error.Record("DataFormat.Error",
                "Not a legacy Excel file (missing CFB container signature).",
                [Expected = "D0CF11E0A1B11AE1",
                 Actual   = if total < 8 then "file shorter than 8 bytes" else Hex(Slice(bin, 0, 8))]),

    SectShift  = if MagicCheck then UInt2At(bin, 30) else 9,
    Sect       = Number.Power(2, SectShift),
    Mini       = Number.Power(2, UInt2At(bin, 32)),
    NFat       = UInt4At(bin, 44),
    DirFirst   = UInt4At(bin, 48),
    MiniCutoff = UInt4At(bin, 56),
    MiniFirst  = UInt4At(bin, 60),
    DifatFirst = UInt4At(bin, 68),
    NDifat     = UInt4At(bin, 72),

    SectorOff = (n as number) as number => 512 + n * Sect,
    MaxChain  = Number.IntegerDivide(total, Sect) + 2,

    // DIFAT: 109 entries in the header, then chained DIFAT sectors
    DifatHead  = List.Transform({0 .. 108}, (i) => UInt4At(bin, 76 + 4 * i)),
    DifatExtra = List.Combine(List.Generate(
        () => [S = DifatFirst, N = 0],
        (s) => s[S] < 0xFFFFFFFC and s[N] < NDifat,
        (s) => [S = UInt4At(bin, SectorOff(s[S]) + Sect - 4), N = s[N] + 1],
        (s) => List.Transform({0 .. Number.IntegerDivide(Sect, 4) - 2},
                   (i) => UInt4At(bin, SectorOff(s[S]) + 4 * i)))),
    FatSects = List.Buffer(List.FirstN(
        List.Select(DifatHead & DifatExtra, (x) => x < 0xFFFFFFFC), NFat)),

    FatPer = Number.IntegerDivide(Sect, 4),
    FatAt  = (n as number) as number =>
        UInt4At(bin, SectorOff(FatSects{Number.IntegerDivide(n, FatPer)}) + 4 * Number.Mod(n, FatPer)),

    Chain = (first as number) as list =>
        List.Generate(
            () => [S = first, N = 0],
            (s) => s[S] < 0xFFFFFFFC and s[N] < MaxChain,
            (s) => [S = FatAt(s[S]), N = s[N] + 1],
            (s) => s[S]),

    ReadChain = (first as number, size as number) as binary =>
        Slice(Binary.Combine(List.Transform(Chain(first),
            (s) => Slice(bin, SectorOff(s), List.Min({Sect, total - SectorOff(s)})))), 0, size),

    // directory entries: 128 bytes each — name (UTF-16), type at 66, start at 116, size at 120
    DirBytes = Binary.Buffer(ReadChain(DirFirst, List.Count(Chain(DirFirst)) * Sect)),
    DirEntries = List.Transform({0 .. Number.IntegerDivide(Binary.Length(DirBytes), 128) - 1},
        (i) => let o  = i * 128,
                   cb = UInt2At(DirBytes, o + 64)
               in  [Name  = if cb >= 2 then Text.FromBinary(Slice(DirBytes, o, cb - 2), TextEncoding.Unicode) else "",
                    Type  = ByteAt(DirBytes, o + 66),
                    Start = UInt4At(DirBytes, o + 116),
                    Size  = UInt4At(DirBytes, o + 120)]),

    RootEntry  = List.First(List.Select(DirEntries, (e) => e[Type] = 5)),
    MiniStream = Binary.Buffer(ReadChain(RootEntry[Start], RootEntry[Size])),
    MiniFatBytes = Binary.Buffer(
        if MiniFirst >= 0xFFFFFFFC then #binary({})
        else ReadChain(MiniFirst, List.Count(Chain(MiniFirst)) * Sect)),

    MiniChain = (first as number) as list =>
        List.Generate(
            () => [S = first, N = 0],
            (s) => s[S] < 0xFFFFFFFC and 4 * s[S] + 4 <= Binary.Length(MiniFatBytes)
                   and s[N] < MaxChain * Number.IntegerDivide(Sect, Mini),
            (s) => [S = UInt4At(MiniFatBytes, 4 * s[S]), N = s[N] + 1],
            (s) => s[S]),

    StreamOf = (e as record) as binary =>
        if e[Size] < MiniCutoff then
            Slice(Binary.Combine(List.Transform(MiniChain(e[Start]),
                (s) => Slice(MiniStream, s * Mini,
                             List.Min({Mini, Binary.Length(MiniStream) - s * Mini})))), 0, e[Size])
        else ReadChain(e[Start], e[Size]),

    WbEntry =
        let hits = List.Select(DirEntries,
                       (e) => e[Type] = 2 and (e[Name] = "Workbook" or e[Name] = "Book"))
        in  if List.IsEmpty(hits)
            then error Error.Record("DataFormat.Error",
                     "No Workbook stream found in the CFB container — not an Excel file.", null)
            else List.First(List.Sort(hits, (e) => if e[Name] = "Workbook" then 0 else 1)),

    stream = Binary.Buffer(StreamOf(WbEntry)),
    streamLen = Binary.Length(stream),

    //==================== BIFF8 record walk ====================
    // record header: id (2 bytes) + payload length (2 bytes); a substream ends at EOF
    RecordsFrom = (start as number) as list =>
        List.Generate(
            () => if start + 4 > streamLen then null
                  else [Rid = UInt2At(stream, start), Off = start + 4,
                        Len = UInt2At(stream, start + 2)],
            (r) => r <> null,
            (r) => let nxt = r[Off] + r[Len]
                   in  if r[Rid] = 0x000A or nxt + 4 > streamLen then null
                       else [Rid = UInt2At(stream, nxt), Off = nxt + 4,
                             Len = UInt2At(stream, nxt + 2)]),

    // XLUnicodeString / XLUnicodeRichExtendedString inside a single record,
    // clamped to the record's end; rich runs and phonetic data are skipped
    XlStrAt = (off as number, recEnd as number, short as logical) as record =>
        let cch   = if short then ByteAt(stream, off) else UInt2At(stream, off),
            p     = off + (if short then 1 else 2),
            grbit = ByteAt(stream, p),
            wide  = Number.BitwiseAnd(grbit, 1) = 1,
            rich  = Number.BitwiseAnd(grbit, 8) = 8,
            ext   = Number.BitwiseAnd(grbit, 4) = 4,
            hdr   = (if rich then 2 else 0) + (if ext then 4 else 0),
            chars = p + 1 + hdr,
            need  = cch * (if wide then 2 else 1),
            have  = recEnd - chars,
            take  = if need <= have then need
                    else if OptStrict then
                        error Error.Record("DataFormat.Error",
                            "Inline string spans a CONTINUE record — not supported.",
                            [Offset = off])
                    else List.Max({0, have}),
            raw   = Slice(stream, chars, take)
        in  [Text = if wide then Text.FromBinary(raw, TextEncoding.Unicode) else Latin1(raw),
             Size = (if short then 1 else 2) + 1 + hdr + take],

    //==================== globals substream ====================
    GRecs = List.Buffer(RecordsFrom(0)),

    BofCheck =
        let first = if List.IsEmpty(GRecs) then null else GRecs{0},
            vers  = if first <> null and first[Rid] = 0x0809 then UInt2At(stream, first[Off]) else null
        in
            if vers = null then
                error Error.Record("DataFormat.Error",
                    "Workbook stream does not start with a BOF record.", null)
            else if vers <> 0x0600 then
                error Error.Record("DataFormat.Error",
                    "Only BIFF8 (Excel 97-2003) is supported; this file uses an older " &
                    "BIFF version (Excel 5.0/95 or earlier).",
                    [BofVersion = vers])
            else true,

    FilePassCheck =
        if BofCheck and not List.IsEmpty(List.Select(GRecs, (r) => r[Rid] = 0x002F))
        then error Error.Record("DataFormat.Error",
                 "The workbook is encrypted or password-protected — not supported.", null)
        else true,

    Date1904 =
        let dm = List.Select(GRecs, (r) => r[Rid] = 0x0022)
        in  not List.IsEmpty(dm) and UInt2At(stream, dm{0}[Off]) = 1,

    // FORMAT records: ifmt -> format code
    FormatsRec = Record.FromList(
        List.Transform(List.Select(GRecs, (r) => r[Rid] = 0x041E),
            (r) => XlStrAt(r[Off] + 2, r[Off] + r[Len], false)[Text]),
        List.Transform(List.Select(GRecs, (r) => r[Rid] = 0x041E),
            (r) => Number.ToText(UInt2At(stream, r[Off])))),

    // XF records in file order: xf index -> ifmt
    XfIfmts = List.Buffer(List.Transform(
        List.Select(GRecs, (r) => r[Rid] = 0x00E0),
        (r) => UInt2At(stream, r[Off] + 2))),

    // BOUNDSHEET: substream offset (4), visibility (byte, low 2 bits),
    // sheet type (byte: 0 = worksheet), short name
    Boundsheets = List.Transform(
        List.Select(GRecs, (r) => r[Rid] = 0x0085),
        (r) => [Offset  = UInt4At(stream, r[Off]),
                Hidden  = Number.BitwiseAnd(ByteAt(stream, r[Off] + 4), 3) <> 0,
                IsSheet = ByteAt(stream, r[Off] + 5) = 0,
                Name    = XlStrAt(r[Off] + 6, r[Off] + r[Len], true)[Text]]),

    // FilePassCheck (which forces BofCheck) is threaded here so the validation
    // runs on every evaluation path — a binding nothing references never runs
    BoundsheetCheck =
        if FilePassCheck and List.IsEmpty(Boundsheets)
        then error Error.Record("DataFormat.Error",
                 "The workbook lists no sheets (no BOUNDSHEET records).", null)
        else Boundsheets,

    //==================== SST across CONTINUE records ====================
    // The SST payload plus following CONTINUE payloads form segments. A string's
    // character data may stop at a segment end and resume in the next segment
    // after a fresh flags byte (which can switch between 8- and 16-bit characters).
    SstSegments =
        let idxs = List.Positions(GRecs),
            sstI = List.Select(idxs, (i) => GRecs{i}[Rid] = 0x00FC)
        in
            if List.IsEmpty(sstI) then null
            else
                let i0    = sstI{0},
                    conts = List.Generate(
                        () => i0 + 1,
                        (i) => i < List.Count(GRecs) and GRecs{i}[Rid] = 0x003C,
                        (i) => i + 1)
                in  List.Buffer(List.Transform({i0} & conts,
                        (i) => Binary.Buffer(Slice(stream, GRecs{i}[Off], GRecs{i}[Len])))),

    SstStrings = List.Buffer(if SstSegments = null then {} else
        let
            segs = SstSegments,
            nseg = List.Count(segs),
            LenOf = (k as number) as number => Binary.Length(segs{k}),
            // skip exhausted segments (headers and skips may straddle freely)
            Norm = (st as record) as record =>
                if st[Seg] < nseg and st[Off] >= LenOf(st[Seg])
                then @Norm([Seg = st[Seg] + 1, Off = 0])
                else st,
            U8 = (st as record) as record =>
                let s = Norm(st)
                in  if s[Seg] >= nseg
                    then error Error.Record("DataFormat.Error", "SST is truncated.", null)
                    else [V = ByteAt(segs{s[Seg]}, s[Off]), St = [Seg = s[Seg], Off = s[Off] + 1]],
            U16 = (st as record) as record =>
                let a = U8(st), b = U8(a[St]) in [V = a[V] + b[V] * 256, St = b[St]],
            U32 = (st as record) as record =>
                let a = U16(st), b = U16(a[St]) in [V = a[V] + b[V] * 65536, St = b[St]],
            SkipN = (st as record, n as number) as record =>
                if n = 0 then st
                else
                    let s = Norm(st)
                    in  if s[Seg] >= nseg
                        then error Error.Record("DataFormat.Error", "SST is truncated.", null)
                        else
                            let take = List.Min({n, LenOf(s[Seg]) - s[Off]})
                            in  @SkipN([Seg = s[Seg], Off = s[Off] + take], n - take),
            // character data: crossing a segment boundary re-reads a flags byte
            Chars = (st as record, cch as number, wide as logical) as record =>
                if cch = 0 then [V = "", St = st]
                else
                    let s     = st,
                        avail = LenOf(s[Seg]) - s[Off],
                        unit  = if wide then 2 else 1
                    in
                        if avail < unit then
                            let nxt = s[Seg] + 1,
                                g   = if nxt >= nseg
                                      then error Error.Record("DataFormat.Error", "SST is truncated.", null)
                                      else ByteAt(segs{nxt}, 0)
                            in  @Chars([Seg = nxt, Off = 1], cch, Number.BitwiseAnd(g, 1) = 1)
                        else
                            let take = List.Min({cch, Number.IntegerDivide(avail, unit)}),
                                raw  = Slice(segs{s[Seg]}, s[Off], take * unit),
                                txt  = if wide then Text.FromBinary(raw, TextEncoding.Unicode) else Latin1(raw),
                                rest = @Chars([Seg = s[Seg], Off = s[Off] + take * unit], cch - take, wide)
                            in  [V = txt & rest[V], St = rest[St]],
            ParseOne = (st as record) as record =>
                let cch   = U16(st),
                    grbit = U8(cch[St]),
                    wide  = Number.BitwiseAnd(grbit[V], 1) = 1,
                    rich  = Number.BitwiseAnd(grbit[V], 8) = 8,
                    ext   = Number.BitwiseAnd(grbit[V], 4) = 4,
                    crun  = if rich then U16(grbit[St]) else [V = 0, St = grbit[St]],
                    cbext = if ext then U32(crun[St]) else [V = 0, St = crun[St]],
                    chars = Chars(cbext[St], cch[V], wide),
                    after = SkipN(chars[St], crun[V] * 4 + cbext[V])
                in  [V = chars[V], St = after],
            unique = UInt4At(segs{0}, 4)
        in
            List.Generate(
                () => if unique = 0 then null else [N = 0, P = ParseOne([Seg = 0, Off = 8])],
                (s) => s <> null,
                (s) => if s[N] + 1 >= unique then null else [N = s[N] + 1, P = ParseOne(s[P][St])],
                (s) => s[P][V])),

    SstAt = (i as number) as any =>
        if i < List.Count(SstStrings) then SstStrings{i}
        else if OptStrict then error Error.Record("DataFormat.Error",
                 "Shared-string index out of range.", [Index = i, Count = List.Count(SstStrings)])
        else null,

    //==================== date detection ====================
    // builtin date/time number formats per [MS-XLS]/ECMA-376
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

    IsDateXf = (xf as number) as logical =>
        OptDates and (
        let ifmt = if xf < List.Count(XfIfmts) then XfIfmts{xf} else 0,
            code = Record.FieldOrDefault(FormatsRec, Number.ToText(ifmt), null)
        in  List.Contains(DateBuiltins, ifmt)
            or (code <> null and IsDateCode(code))),

    // Excel serial -> datetime. Serials below 61 use the 1899-12-31 epoch so that
    // displayed dates match Excel (Lotus leap-year bug); 60 becomes 1900-03-01.
    SerialToDateTime = (v as number) as datetime =>
        if Date1904 then #datetime(1904, 1, 1, 0, 0, 0) + #duration(0, 0, 0, v * 86400)
        else if v >= 61 then #datetime(1899, 12, 30, 0, 0, 0) + #duration(0, 0, 0, v * 86400)
        else #datetime(1899, 12, 31, 0, 0, 0) + #duration(0, 0, 0, v * 86400),

    NumOrDate = (v as number, xf as number) as any =>
        if IsDateXf(xf) then SerialToDateTime(v) else v,

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

    //==================== worksheet substream -> cells ====================
    // every BIFF8 cell record carries its own row; MULRK/MULBLANK emit runs
    SheetCells = (start as number) as list =>
        let
            recs = List.Buffer(RecordsFrom(start)),
            RecCells = (i as number) as list =>
                let r   = recs{i},
                    rid = r[Rid],
                    o   = r[Off],
                    rw  = UInt2At(stream, o),
                    col = UInt2At(stream, o + 2),
                    xf  = UInt2At(stream, o + 4)
                in
                    if rid = 0x027E then                                        // RK
                        {[R = rw, C = col, V = NumOrDate(RkValue(UInt4At(stream, o + 6)), xf)]}
                    else if rid = 0x00BD then                                   // MULRK
                        let n = Number.IntegerDivide(r[Len] - 6, 6)
                        in  List.Transform({0 .. n - 1}, (m) =>
                                [R = rw, C = col + m,
                                 V = NumOrDate(RkValue(UInt4At(stream, o + 6 + 6 * m)),
                                               UInt2At(stream, o + 4 + 6 * m))])
                    else if rid = 0x0203 then                                   // NUMBER
                        {[R = rw, C = col, V = NumOrDate(Float8At(stream, o + 6), xf)]}
                    else if rid = 0x00FD then                                   // LABELSST
                        {[R = rw, C = col, V = SstAt(UInt4At(stream, o + 6))]}
                    else if rid = 0x0204 or rid = 0x00D6 then                   // LABEL / RSTRING
                        {[R = rw, C = col, V = XlStrAt(o + 6, o + r[Len], false)[Text]]}
                    else if rid = 0x0205 then                                   // BOOLERR
                        let v = ByteAt(stream, o + 6)
                        in  {[R = rw, C = col,
                              V = if ByteAt(stream, o + 7) = 1 then CellError(v) else v <> 0]}
                    else if rid = 0x0201 then                                   // BLANK
                        {[R = rw, C = col, V = null]}
                    else if rid = 0x00BE then                                   // MULBLANK
                        let n = Number.IntegerDivide(r[Len] - 6, 2)
                        in  List.Transform({0 .. n - 1}, (m) => [R = rw, C = col + m, V = null])
                    else if rid = 0x0006 then                                   // FORMULA
                        let special = UInt2At(stream, o + 12) = 0xFFFF,
                            tag     = ByteAt(stream, o + 6),
                            v =
                                if not special then NumOrDate(Float8At(stream, o + 6), xf)
                                else if tag = 0 then                            // string result follows
                                    let nxt = List.Generate(
                                            () => i + 1,
                                            (j) => j < List.Count(recs) and
                                                   List.Contains({0x0221, 0x0236, 0x04BC, 0x003C},
                                                                 recs{j}[Rid]),
                                            (j) => j + 1),
                                        j = i + List.Count(nxt) + 1
                                    in  if j < List.Count(recs) and recs{j}[Rid] = 0x0207
                                        then XlStrAt(recs{j}[Off], recs{j}[Off] + recs{j}[Len], false)[Text]
                                        else ""
                                else if tag = 1 then ByteAt(stream, o + 8) <> 0
                                else if tag = 2 then CellError(ByteAt(stream, o + 8))
                                else ""                                         // tag 3: empty string
                        in  {[R = rw, C = col, V = v]}
                    else
                        {}
        in
            List.Combine(List.Transform(List.Positions(recs), RecCells)),

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

    //==================== navigation table ====================
    Shown = List.Select(BoundsheetCheck,
        (b) => b[IsSheet] and (OptHidden or not b[Hidden])),

    NavRows = List.Transform(Shown, (b) =>
        {b[Name], GridFromCells(SheetCells(b[Offset])), b[Hidden], "Sheet", "Sheet", true}),

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
          meta [Xls.Date1904 = Date1904]
in
    Nav
