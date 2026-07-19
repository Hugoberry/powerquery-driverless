// SPDX-License-Identifier: Apache-2.0
//
// Evtx.Document.pq — read Windows XML Event Log (.evtx) files in pure Power Query M.
// No Windows Event Log API, no SIEM, no ODBC driver, no custom connector required.
// Paste into a blank query (name it Evtx.Document), or wrap as a function in your PBIX / dataflow.
//
// Usage:
//   let
//       Evtx.Document = <this expression>,
//       t = Evtx.Document(File.Contents("C:\path\to\Security.evtx"))
//   in
//       t
//
// Options (optional second argument, all keys optional):
//   IncludeXml  logical, default true — emit the rendered XML of every event in an
//               Xml column. Set false to skip rendering when only the extracted
//               columns are needed (faster on large logs).
//   Encoding    TextEncoding or codepage number for AnsiString (type 0x02) values,
//               default Windows-1252. Unicode strings are unaffected.
//   MaxRows     number — stop after this many events.
//   Strict      logical, default false — when false, records that fail to parse are
//               skipped (their count is reported in the Evtx.SkippedRecords metadata)
//               and chunks with bad signatures are ignored, which is how a dirty or
//               partially written log is recovered. When true, any malformation is
//               an error.
//
// Supported: EVTX version 3.1 and 3.2 (Vista through current Windows); binary XML
//            templates, resident and back-referenced, nested binary XML values;
//            all documented substitution value types (strings, integers, floats,
//            boolean, binary, GUID, FILETIME, SYSTEMTIME, SID, hex32/64, size_t,
//            Unicode string arrays); dirty files (chunks are discovered by
//            signature scan, not the header count, and record recovery stops at
//            the first corrupt record of a chunk); files with records outside any
//            template (raw fragments).
// Not supported: legacy .evt files (a different format entirely — clear error);
//            CRC32 checksum verification (checksums are ignored; a corrupt file
//            surfaces as skipped records instead); carving records from chunk
//            slack space.
// Precision: 64-bit integer values beyond 2^53 lose precision (M numbers are
//            doubles); FILETIME timestamps are decoded exactly to the 100ns tick.
// Output:    a table with one row per event — RecordId, TimeCreated, Provider,
//            EventId, Level, LevelName, Task, Opcode, Keywords, Channel, Computer,
//            ProcessId, ThreadId, UserId, EventData (a record of the event's
//            payload fields), Xml (the rendered event XML) — with Evtx.Version,
//            Evtx.IsDirty, Evtx.IsFull, Evtx.NextRecordId, Evtx.ChunkCount,
//            Evtx.DeclaredChunkCount and Evtx.SkippedRecords in the table metadata.
//            Events from non-Event schemas keep their XML and EventData-style
//            payload where recognizable; System columns are null for them.

(source as binary, optional options as nullable record) as table =>
let
    bin   = Binary.Buffer(source),
    total = Binary.Length(bin),

    opts          = if options = null then [] else options,
    OptStrict     = Record.FieldOrDefault(opts, "Strict", false) = true,
    OptMaxRows    = Record.FieldOrDefault(opts, "MaxRows", null),
    OptIncludeXml = Record.FieldOrDefault(opts, "IncludeXml", true) = true,
    OptEncoding   = let e = Record.FieldOrDefault(opts, "Encoding", null)
                    in  if e = null then 1252 else e,

    //==================== low-level byte access ====================
    Slice = (b as binary, offset as number, count as number) as binary =>
        if count <= 0 then #binary({})
        else if offset = 0 then BinaryFormat.Binary(count)(b)
        else BinaryFormat.Record([
                Skip = BinaryFormat.Binary(offset),
                Data = BinaryFormat.Binary(count)
             ])(b)[Data],

    U16Fmt = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger16, ByteOrder.LittleEndian),
    U32Fmt = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger32, ByteOrder.LittleEndian),
    F32Fmt = BinaryFormat.ByteOrder(BinaryFormat.Single, ByteOrder.LittleEndian),
    F64Fmt = BinaryFormat.ByteOrder(BinaryFormat.Double, ByteOrder.LittleEndian),

    ByteOf = (b as binary, off as number) as number => Binary.ToList(Slice(b, off, 1)){0},
    U16Of  = (b as binary, off as number) as number => U16Fmt(Slice(b, off, 2)),
    U32Of  = (b as binary, off as number) as number => U32Fmt(Slice(b, off, 4)),
    U64Of  = (b as binary, off as number) as number =>          // exact only below 2^53
        U32Of(b, off) + U32Of(b, off + 4) * 4294967296,

    NumList = (n as number) as list => if n <= 0 then {} else {0 .. n - 1},
    NulChar = Character.FromNumber(0),
    TrimNul = (t as text) as text => Text.TrimEnd(t, {NulChar}),
    Utf16At = (b as binary, off as number, nchars as number) as text =>
        if nchars = 0 then "" else Text.FromBinary(Slice(b, off, 2 * nchars), TextEncoding.Utf16),

    ByteHex  = (n as number) as text => Text.PadStart(Number.ToText(n, "x"), 2, "0"),
    BytesHex = (bytes as list) as text => Text.Combine(List.Transform(bytes, ByteHex)),

    //==================== FILETIME / SYSTEMTIME ====================
    // A FILETIME qword (100ns ticks since 1601-01-01) exceeds 2^53, so it cannot
    // pass through a single M number without losing ticks. Byte-wise long
    // division keeps every intermediate below 2^53 (max is 864e9 * 256, about
    // 2^47.7): the value becomes whole days plus a tick-of-day remainder, both
    // exact.
    TicksPerDay = 864000000000,
    FtPartsOf = (b as binary, off as number) as record =>
        let
            hilo = List.Accumulate(List.Reverse(Binary.ToList(Slice(b, off, 8))),
                       [Q = 0, R = 0],
                       (st, byte) =>
                           let t = st[R] * 256 + byte
                           in  [Q = st[Q] * 256 + Number.IntegerDivide(t, TicksPerDay),
                                R = Number.Mod(t, TicksPerDay)])
        in
            [Days = hilo[Q], Ticks = hilo[R]],

    FtEpoch = #datetime(1601, 1, 1, 0, 0, 0),
    FtDateTime = (ft as record) as datetime =>
        FtEpoch + #duration(ft[Days], 0, 0, 0) + #duration(0, 0, 0, ft[Ticks] / 10000000),
    FtText = (ft as record) as text =>
        let whole = FtEpoch + #duration(ft[Days], 0, 0, 0)
                            + #duration(0, 0, 0, Number.IntegerDivide(ft[Ticks], 10000000))
        in  DateTime.ToText(whole, "yyyy-MM-dd'T'HH:mm:ss") & "." &
            Text.PadStart(Number.ToText(Number.Mod(ft[Ticks], 10000000)), 7, "0") & "Z",

    StDateTime = (w as list) as datetime =>       // year month dayofweek day h m s ms
        #datetime(w{0}, w{1}, w{3}, w{4}, w{5}, w{6}) + #duration(0, 0, 0, w{7} / 1000),
    StText = (w as list) as text =>
        DateTime.ToText(#datetime(w{0}, w{1}, w{3}, w{4}, w{5}, w{6}), "yyyy-MM-dd'T'HH:mm:ss")
        & "." & Text.PadStart(Number.ToText(w{7}), 3, "0") & "Z",

    //==================== GUID / SID ====================
    GuidText = (raw as binary) as text =>
        let l = Binary.ToList(raw)
        in  Text.Upper(
                "{" & BytesHex({l{3}, l{2}, l{1}, l{0}}) &
                "-" & BytesHex({l{5}, l{4}}) &
                "-" & BytesHex({l{7}, l{6}}) &
                "-" & BytesHex({l{8}, l{9}}) &
                "-" & BytesHex({l{10}, l{11}, l{12}, l{13}, l{14}, l{15}}) & "}"),

    SidText = (raw as binary) as text =>
        let
            l         = Binary.ToList(raw),
            count     = l{1},
            authority = List.Accumulate({l{2}, l{3}, l{4}, l{5}, l{6}, l{7}}, 0,
                                        (s, c) => s * 256 + c),
            subs      = List.Transform(NumList(count), (i) => U32Of(raw, 8 + 4 * i))
        in
            Text.Combine({"S", Number.ToText(l{0}), Number.ToText(authority)}
                         & List.Transform(subs, Number.ToText), "-"),

    //==================== substitution value decoding ====================
    // Substitution data declares each value's byte size, so values carry no
    // count prefixes of their own. Values are canonical items:
    //   [Kind="val", VType, Value] or [Kind="xml", Items] for nested binary XML.
    SignedOf = (u as number, bits as number) as number =>
        if u >= Number.Power(2, bits - 1) then u - Number.Power(2, bits) else u,

    //==================== per-chunk parser ====================
    // Every offset inside a chunk is chunk-relative, so each 64 KiB chunk is
    // sliced out, buffered, and parsed as its own little world: name strings
    // and template definitions are prescanned from the chunk's hash tables
    // (with a direct-parse fallback for entries a dirty table fails to link),
    // then records are walked from offset 0x200.
    ParseChunk = (chunkBin as binary) as record =>
        let
            chunk = Binary.Buffer(chunkBin),

            //-------- name strings: next(4) hash(2) nchars(2) utf16 nul(2)
            NameAt = (off as number) as record =>
                let nchars = U16Of(chunk, off + 6)
                in  [Name = Utf16At(chunk, off + 8, nchars), Size = 8 + 2 * nchars + 2],

            WalkBucket = (headOff as number) as list =>
                List.Generate(
                    () => [Off = headOff, N = 0],
                    (s) => s[Off] > 0 and s[Off] < 65536 and s[N] < 10000,
                    (s) => [Off = U32Of(chunk, s[Off]), N = s[N] + 1],
                    (s) => s[Off]),

            NameOffsets = List.Distinct(List.Combine(List.Transform(NumList(64),
                              (i) => WalkBucket(U32Of(chunk, 128 + 4 * i))))),
            Names = Record.FromList(
                        List.Transform(NameOffsets, (o) => NameAt(o)[Name]),
                        List.Transform(NameOffsets, Number.ToText)),
            LookupName = (off as number) as text =>
                let hit = Record.FieldOrDefault(Names, Number.ToText(off), null)
                in  if hit <> null then hit else NameAt(off)[Name],

            //-------- one scalar token in value position: [Item, Next, More]
            ValueItemAt = (pos as number) as record =>
                let
                    tok  = ByteOf(chunk, pos),
                    kind = Number.Mod(tok, 16),
                    more = Number.BitwiseAnd(tok, 64) <> 0
                in
                    if kind = 5 then
                        let
                            vtype = ByteOf(chunk, pos + 1),
                            check = if vtype <> 1
                                    then error Error.Record("DataFormat.Error",
                                            "Value token with a non-string type.",
                                            [Type = vtype, Offset = pos])
                                    else true,
                            nchars = if check then U16Of(chunk, pos + 2) else 0
                        in
                            [Item = [Kind = "text", Text = Utf16At(chunk, pos + 4, nchars)],
                             Next = pos + 4 + 2 * nchars, More = more]
                    else if kind = 13 or kind = 14 then
                        [Item = [Kind = "sub", Index = U16Of(chunk, pos + 1),
                                 VType = ByteOf(chunk, pos + 3), Cond = kind = 14],
                         Next = pos + 4, More = more]
                    else if kind = 8 then
                        [Item = [Kind = "charref", Code = U16Of(chunk, pos + 1)],
                         Next = pos + 3, More = more]
                    else if kind = 9 then
                        let
                            nameOff = U32Of(chunk, pos + 1),
                            next    = if nameOff = pos + 5
                                      then pos + 5 + NameAt(nameOff)[Size]
                                      else pos + 5
                        in
                            [Item = [Kind = "entityref", Name = LookupName(nameOff)],
                             Next = next, More = more]
                    else
                        error Error.Record("DataFormat.Error",
                            "Unexpected token in value position.",
                            [Token = tok, Offset = pos]),

            //-------- attribute list: [Attrs, Next]
            AttrsAt = (pos as number, acc as list) as record =>
                if Number.Mod(ByteOf(chunk, pos), 16) <> 6 then [Attrs = acc, Next = pos]
                else
                    let
                        atok    = ByteOf(chunk, pos),
                        nameOff = U32Of(chunk, pos + 1),
                        afterNm = if nameOff = pos + 5
                                  then pos + 5 + NameAt(nameOff)[Size]
                                  else pos + 5,
                        Parts = (p as number, ac as list) as record =>
                            let v = ValueItemAt(p)
                            in  if v[More] then @Parts(v[Next], ac & {v[Item]})
                                else [Parts = ac & {v[Item]}, Next = v[Next]],
                        parts = Parts(afterNm, {}),
                        attr  = [Name = LookupName(nameOff), Parts = parts[Parts]],
                        out   = acc & {attr}
                    in
                        if Number.BitwiseAnd(atok, 64) = 0
                        then [Attrs = out, Next = parts[Next]]
                        else @AttrsAt(parts[Next], out),

            //-------- element: [Item, Next]
            ElementAt = (pos as number) as record =>
                let
                    tok      = ByteOf(chunk, pos),
                    hasAttrs = Number.BitwiseAnd(tok, 64) <> 0,
                    nameOff  = U32Of(chunk, pos + 7),
                    afterNm  = if nameOff = pos + 11
                               then pos + 11 + NameAt(nameOff)[Size]
                               else pos + 11,
                    attrsRes = if hasAttrs then AttrsAt(afterNm + 4, {})
                               else [Attrs = {}, Next = afterNm],
                    closeTok = ByteOf(chunk, attrsRes[Next]),
                    name     = LookupName(nameOff)
                in
                    if closeTok = 3 then
                        [Item = [Kind = "elem", Name = name, Empty = true,
                                 Attrs = attrsRes[Attrs], Content = {}],
                         Next = attrsRes[Next] + 1]
                    else if closeTok = 2 then
                        let c = ContentAt(attrsRes[Next] + 1, {})
                        in  [Item = [Kind = "elem", Name = name, Empty = false,
                                     Attrs = attrsRes[Attrs], Content = c[Items]],
                             Next = c[Next]]
                    else
                        error Error.Record("DataFormat.Error",
                            "Expected a close-start-element token.",
                            [Token = closeTok, Offset = attrsRes[Next]]),

            //-------- element content until the end-element token: [Items, Next]
            ContentAt = (pos as number, acc as list) as record =>
                let
                    tok  = ByteOf(chunk, pos),
                    kind = Number.Mod(tok, 16)
                in
                    if kind = 4 then [Items = acc, Next = pos + 1]
                    else if kind = 1 then
                        let e = ElementAt(pos)
                        in  @ContentAt(e[Next], acc & {e[Item]})
                    else if kind = 5 or kind = 8 or kind = 9 or kind = 13 or kind = 14 then
                        let v = ValueItemAt(pos)
                        in  @ContentAt(v[Next], acc & {v[Item]})
                    else if kind = 7 then
                        let nchars = U16Of(chunk, pos + 1)
                        in  @ContentAt(pos + 3 + 2 * nchars,
                                       acc & {[Kind = "cdata", Text = Utf16At(chunk, pos + 3, nchars)]})
                    else if kind = 10 then
                        let
                            nameOff = U32Of(chunk, pos + 1),
                            afterNm = if nameOff = pos + 5
                                      then pos + 5 + NameAt(nameOff)[Size]
                                      else pos + 5,
                            hasData = Number.Mod(ByteOf(chunk, afterNm), 16) = 11,
                            nchars  = if hasData then U16Of(chunk, afterNm + 1) else 0,
                            data    = if hasData then Utf16At(chunk, afterNm + 3, nchars) else "",
                            next    = if hasData then afterNm + 3 + 2 * nchars else afterNm
                        in
                            @ContentAt(next, acc & {[Kind = "pi", Target = LookupName(nameOff),
                                                     Data = data]})
                    else
                        error Error.Record("DataFormat.Error",
                            "Unexpected token in element content.",
                            [Token = tok, Offset = pos]),

            //-------- fragment body until the end-of-stream token: [Items, Next]
            FragmentItemsAt = (pos as number, acc as list) as record =>
                let
                    tok  = ByteOf(chunk, pos),
                    kind = Number.Mod(tok, 16)
                in
                    if kind = 0 then [Items = acc, Next = pos + 1]
                    else if kind = 1 then
                        let e = ElementAt(pos)
                        in  @FragmentItemsAt(e[Next], acc & {e[Item]})
                    else if kind = 5 or kind = 8 or kind = 9 or kind = 13 or kind = 14 then
                        let v = ValueItemAt(pos)
                        in  @FragmentItemsAt(v[Next], acc & {v[Item]})
                    else
                        error Error.Record("DataFormat.Error",
                            "Unexpected token at fragment level.",
                            [Token = tok, Offset = pos]),

            //-------- template definitions: next(4) guid(16) datasize(4) fragment
            IsFragmentHeaderAt = (pos as number) as logical =>
                ByteOf(chunk, pos) = 15 and ByteOf(chunk, pos + 1) = 1 and
                ByteOf(chunk, pos + 2) = 1 and ByteOf(chunk, pos + 3) = 0,

            TemplateBodyAt = (defOff as number) as list =>
                if not IsFragmentHeaderAt(defOff + 24)
                then error Error.Record("DataFormat.Error",
                        "Template definition does not start with a fragment header.",
                        [Offset = defOff])
                else FragmentItemsAt(defOff + 28, {})[Items],

            TemplateOffsets = List.Distinct(List.Combine(List.Transform(NumList(32),
                                  (i) => WalkBucket(U32Of(chunk, 384 + 4 * i))))),
            Templates = Record.FromList(
                            List.Transform(TemplateOffsets, TemplateBodyAt),
                            List.Transform(TemplateOffsets, Number.ToText)),
            LookupTemplate = (defOff as number) as list =>
                let hit = Record.FieldOrDefault(Templates, Number.ToText(defOff), null)
                in  if hit <> null then hit else TemplateBodyAt(defOff),

            //-------- substitution values
            DecodeValueAt = (pos as number, size as number, vtype as number) as record =>
                let raw = Slice(chunk, pos, size)
                in
                    if vtype = 0 or (size = 0 and vtype <> 1 and vtype <> 2
                                     and vtype <> 14 and vtype <> 129)
                    then [Kind = "val", VType = 0, Value = null]
                    else if vtype = 1 then
                        [Kind = "val", VType = vtype,
                         Value = TrimNul(if size = 0 then "" else Text.FromBinary(raw, TextEncoding.Utf16))]
                    else if vtype = 2 then
                        [Kind = "val", VType = vtype,
                         Value = TrimNul(if size = 0 then "" else Text.FromBinary(raw, OptEncoding))]
                    else if vtype = 3 then
                        [Kind = "val", VType = vtype, Value = SignedOf(ByteOf(raw, 0), 8)]
                    else if vtype = 4 then
                        [Kind = "val", VType = vtype, Value = ByteOf(raw, 0)]
                    else if vtype = 5 then
                        [Kind = "val", VType = vtype, Value = SignedOf(U16Of(raw, 0), 16)]
                    else if vtype = 6 then
                        [Kind = "val", VType = vtype, Value = U16Of(raw, 0)]
                    else if vtype = 7 then
                        [Kind = "val", VType = vtype, Value = SignedOf(U32Of(raw, 0), 32)]
                    else if vtype = 8 then
                        [Kind = "val", VType = vtype, Value = U32Of(raw, 0)]
                    else if vtype = 9 then
                        [Kind = "val", VType = vtype, Value = SignedOf(U64Of(raw, 0), 64)]
                    else if vtype = 10 then
                        [Kind = "val", VType = vtype, Value = U64Of(raw, 0)]
                    else if vtype = 11 then
                        [Kind = "val", VType = vtype, Value = F32Fmt(raw)]
                    else if vtype = 12 then
                        [Kind = "val", VType = vtype, Value = F64Fmt(raw)]
                    else if vtype = 13 then
                        [Kind = "val", VType = vtype, Value = U32Of(raw, 0) <> 0]
                    else if vtype = 14 then
                        [Kind = "val", VType = vtype, Value = raw]
                    else if vtype = 15 then
                        [Kind = "val", VType = vtype, Value = GuidText(raw)]
                    else if vtype = 16 then
                        [Kind = "val", VType = vtype,
                         Value = if size = 4 then U32Of(raw, 0) else U64Of(raw, 0)]
                    else if vtype = 17 then
                        [Kind = "val", VType = vtype, Value = FtPartsOf(raw, 0)]
                    else if vtype = 18 then
                        [Kind = "val", VType = vtype,
                         Value = List.Transform(NumList(8), (i) => U16Of(raw, 2 * i))]
                    else if vtype = 19 then
                        [Kind = "val", VType = vtype, Value = SidText(raw)]
                    else if vtype = 20 then
                        [Kind = "val", VType = vtype,
                         Value = "0x" & BytesHex(List.Reverse(Binary.ToList(raw)))]
                    else if vtype = 21 then
                        [Kind = "val", VType = vtype,
                         Value = "0x" & BytesHex(List.Reverse(Binary.ToList(raw)))]
                    else if vtype = 33 then
                        [Kind = "xml", Items = RootAt(pos)[Items]]
                    else if vtype = 129 then
                        let
                            decoded = if size = 0 then "" else Text.FromBinary(raw, TextEncoding.Utf16),
                            parts = Text.Split(decoded, NulChar),
                            n     = List.Count(parts),
                            clean = if n > 0 and parts{n - 1} = "" then List.FirstN(parts, n - 1)
                                    else parts
                        in
                            [Kind = "val", VType = vtype, Value = clean]
                    else if OptStrict then
                        error Error.Record("DataFormat.Error",
                            "Unsupported substitution value type.",
                            [Type = vtype, Offset = pos])
                    else [Kind = "val", VType = vtype, Value = raw],

            SubDataAt = (pos as number) as record =>
                let
                    count = U32Of(chunk, pos),
                    check = if count > 4096
                            then error Error.Record("DataFormat.Error",
                                    "Implausible substitution count.",
                                    [Count = count, Offset = pos])
                            else true,
                    decls = if check
                            then List.Transform(NumList(count), (i) =>
                                     [Size = U16Of(chunk, pos + 4 + 4 * i),
                                      VType = ByteOf(chunk, pos + 4 + 4 * i + 2)])
                            else {},
                    vals  = List.Accumulate(decls, [Pos = pos + 4 + 4 * count, Out = {}],
                                (st, d) =>
                                    [Pos = st[Pos] + d[Size],
                                     Out = st[Out] & {DecodeValueAt(st[Pos], d[Size], d[VType])}])
                in
                    [Values = vals[Out], Next = vals[Pos]],

            //-------- substitution of template placeholders
            ResolveItem = (item as record, values as list) as record =>
                if item[Kind] <> "sub" then item
                else if item[Index] >= List.Count(values) then
                    error Error.Record("DataFormat.Error",
                        "Substitution index out of range.",
                        [Index = item[Index], Count = List.Count(values)])
                else values{item[Index]},

            Substitute = (items as list, values as list) as list =>
                List.Transform(items, (item) =>
                    if item[Kind] = "elem" then
                        item & [Attrs = List.Transform(item[Attrs], (a) =>
                                    [Name = a[Name],
                                     Parts = List.Transform(a[Parts], (p) => ResolveItem(p, values))]),
                                Content = @Substitute(item[Content], values)]
                    else ResolveItem(item, values)),

            //-------- a binxml root: fragment, template instance or direct items,
            //         then the substitution array: [Items, Next]
            RootAt = (pos0 as number) as record =>
                let
                    pos = if IsFragmentHeaderAt(pos0) then pos0 + 4 else pos0,
                    tok = ByteOf(chunk, pos)
                in
                    if Number.Mod(tok, 16) = 12 then
                        let
                            defOff  = U32Of(chunk, pos + 6),
                            after   = pos + 10,
                            // resident definition: skip it (already prescanned)
                            subsPos = if defOff = after
                                      then defOff + 24 + U32Of(chunk, defOff + 20)
                                      else after,
                            template = LookupTemplate(defOff),
                            subs     = SubDataAt(subsPos)
                        in
                            [Items = Substitute(template, subs[Values]), Next = subs[Next]]
                    else
                        let
                            frag = FragmentItemsAt(pos, {}),
                            subs = SubDataAt(frag[Next])
                        in
                            [Items = Substitute(frag[Items], subs[Values]), Next = subs[Next]],

            //-------- record walk from 0x200 to the chunk's free-space pointer
            FreeSpace = U32Of(chunk, 48),
            RecHeaderAt = (pos as number) as nullable record =>
                if pos + 28 > FreeSpace then null
                else if U32Of(chunk, pos) <> 10794 then       // 0x00002a2a
                    (if OptStrict
                     then error Error.Record("DataFormat.Error",
                             "Bad event record signature.", [Offset = pos])
                     else null)
                else
                    let size = U32Of(chunk, pos + 4)
                    in
                        if size < 28 or pos + size > FreeSpace
                           or U32Of(chunk, pos + size - 4) <> size
                        then (if OptStrict
                              then error Error.Record("DataFormat.Error",
                                      "Bad event record size.",
                                      [Offset = pos, Size = size])
                              else null)
                        else [Pos = pos, Next = pos + size,
                              RecordId = U64Of(chunk, pos + 8),
                              Written = FtPartsOf(chunk, pos + 16)],

            RecHeaders = List.Generate(
                () => RecHeaderAt(512),
                (r) => r <> null,
                (r) => RecHeaderAt(r[Next])),

            ParseRecord = (r as record) as record =>
                [RecordId = r[RecordId], Written = r[Written],
                 Items = RootAt(r[Pos] + 24)[Items]],

            Parsed = List.Transform(RecHeaders, (r) =>
                         if OptStrict then ParseRecord(r)
                         else let t = try ParseRecord(r)
                              in  if t[HasError] then null else t[Value]),
            Ok = List.Select(Parsed, (p) => p <> null)
        in
            [Records = Ok, Skipped = List.Count(Parsed) - List.Count(Ok)],

    //==================== file header ====================
    CheckMagic =
        if total >= 4096 and Slice(bin, 0, 8) = #binary({69, 108, 102, 70, 105, 108, 101, 0})
        then true
        else if total >= 8 and Slice(bin, 4, 4) = #binary({76, 102, 76, 101}) then   // "LfLe"
            error Error.Record("DataFormat.Error",
                "This is a legacy Windows Event Log (.evt) file, not EVTX. " &
                "The .evt format is not supported.", null)
        else error Error.Record("DataFormat.Error",
                "Not an EVTX file (missing ""ElfFile"" signature).", null),

    MajorVersion = if CheckMagic then U16Of(bin, 38) else 0,
    MinorVersion = U16Of(bin, 36),
    CheckVersion =
        if MajorVersion = 3 then true
        else error Error.Record("DataFormat.Error",
                "Unsupported EVTX version.",
                [Major = MajorVersion, Minor = MinorVersion]),

    Flags          = if CheckVersion then U32Of(bin, 120) else 0,
    IsDirty        = Number.BitwiseAnd(Flags, 1) = 1,
    IsFull         = Number.BitwiseAnd(Flags, 2) = 2,
    NextRecordId   = U64Of(bin, 24),
    DeclaredChunks = U16Of(bin, 42),

    //==================== chunks: discovered by signature scan ====================
    ChunkSig   = #binary({69, 108, 102, 67, 104, 110, 107, 0}),   // "ElfChnk\0"
    SlotCount  = Number.IntegerDivide(total - 4096, 65536),
    ChunkBases = List.Select(
                     List.Transform(NumList(SlotCount), (i) => 4096 + 65536 * i),
                     (base) => Slice(bin, base, 8) = ChunkSig),
    ChunkResults = List.Transform(ChunkBases, (base) => ParseChunk(Slice(bin, base, 65536))),

    AllRecords = List.Combine(List.Transform(ChunkResults, (c) => c[Records])),
    Records    = if OptMaxRows = null then AllRecords else List.FirstN(AllRecords, OptMaxRows),
    Skipped    = List.Sum(List.Transform(ChunkResults, (c) => c[Skipped])),

    //==================== XML rendering ====================
    EscText = (t as text) as text =>
        Text.Replace(Text.Replace(Text.Replace(t, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"),
    EscAttr = (t as text) as text => Text.Replace(EscText(t), """", "&quot;"),

    NumberText = (v as number) as text => Number.ToText(v),

    ValueText = (vtype as number, v) as text =>
        if v = null then ""
        else if vtype = 1 or vtype = 2 or vtype = 15 or vtype = 19 or vtype = 20 or vtype = 21
        then v
        else if vtype = 13 then (if v then "true" else "false")
        else if vtype = 14 then Text.Upper(Binary.ToText(v, BinaryEncoding.Hex))
        else if vtype = 17 then FtText(v)
        else if vtype = 18 then StText(v)
        else if vtype = 129 then Text.Combine(v, "#(lf)")
        else if v is binary then Text.Upper(Binary.ToText(v, BinaryEncoding.Hex))
        else NumberText(v),

    ItemXml = (item as record, inAttr as logical) as text =>
        let k = item[Kind]
        in
            if k = "text" then (if inAttr then EscAttr(item[Text]) else EscText(item[Text]))
            else if k = "val" then
                let t = ValueText(item[VType], item[Value])
                in  if inAttr then EscAttr(t) else EscText(t)
            else if k = "charref" then "&#x" & Number.ToText(item[Code], "x") & ";"
            else if k = "entityref" then "&" & item[Name] & ";"
            else if k = "cdata" then "<![CDATA[" & item[Text] & "]]>"
            else if k = "pi" then "<?" & item[Target] & " " & item[Data] & "?>"
            else if k = "xml" then
                Text.Combine(List.Transform(item[Items], (i) => @ItemXml(i, false)))
            else if k = "elem" then ElemXml(item)
            else error Error.Record("DataFormat.Error", "Unrenderable item.", [Kind = k]),

    ElemXml = (el as record) as text =>
        let
            attrs = Text.Combine(List.Transform(el[Attrs], (a) =>
                        " " & a[Name] & "=""" &
                        Text.Combine(List.Transform(a[Parts], (p) => ItemXml(p, true))) & """"))
        in
            if el[Empty] then "<" & el[Name] & attrs & "/>"
            else "<" & el[Name] & attrs & ">" &
                 Text.Combine(List.Transform(el[Content], (i) => ItemXml(i, false))) &
                 "</" & el[Name] & ">",

    RecordXml = (items as list) as text =>
        Text.Combine(List.Transform(items, (i) => ItemXml(i, false))),

    //==================== column extraction ====================
    LevelNames = {"LogAlways", "Critical", "Error", "Warning", "Informational", "Verbose"},

    ChildElems = (el as nullable record, name as nullable text) as list =>
        if el = null then {}
        else List.Select(el[Content], (c) =>
                 c[Kind] = "elem" and (name = null or c[Name] = name)),
    FirstChild = (el as nullable record, name as nullable text) as nullable record =>
        let hits = ChildElems(el, name)
        in  if List.IsEmpty(hits) then null else hits{0},
    AttrOf = (el as nullable record, name as text) as nullable list =>
        if el = null then null
        else
            let hits = List.Select(el[Attrs], (a) => a[Name] = name)
            in  if List.IsEmpty(hits) then null else hits{0}[Parts],

    EntityChars = [lt = "<", gt = ">", amp = "&", quot = """", apos = "'"],

    // A single substituted value keeps its type (dates become datetimes); mixed
    // or literal content collapses to text.
    TypedValue = (vtype as number, v) as any =>
        if v = null then null
        else if vtype = 17 then FtDateTime(v)
        else if vtype = 18 then StDateTime(v)
        else v,

    ScalarOf = (parts as nullable list) as any =>
        if parts = null then null
        else
            let
                vals = List.Select(parts, (p) =>
                           p[Kind] = "text" or p[Kind] = "val" or
                           p[Kind] = "charref" or p[Kind] = "entityref")
            in
                if List.IsEmpty(vals) then null
                else if List.Count(vals) = 1 and vals{0}[Kind] = "val"
                then TypedValue(vals{0}[VType], vals{0}[Value])
                else Text.Combine(List.Transform(vals, (p) =>
                         if p[Kind] = "text" then p[Text]
                         else if p[Kind] = "val" then ValueText(p[VType], p[Value])
                         else if p[Kind] = "charref" then Character.FromNumber(p[Code])
                         else Record.FieldOrDefault(EntityChars, p[Name], ""))),

    ElemScalar = (el as nullable record) as any =>
        if el = null then null else ScalarOf(el[Content]),

    AsInt = (v) as nullable number =>
        if v = null then null
        else if v is logical then null
        else if v is number then v
        else if v is text then (let t = try Number.FromText(Text.Trim(v))
                                in  if t[HasError] then null else t[Value])
        else null,

    KeywordsText = (v) as nullable text =>
        if v = null then null
        else if v is text then v
        else if v is number then "0x" & Text.PadStart(Number.ToText(v, "x"), 16, "0")
        else Text.From(v),

    TimeOf = (parts as nullable list, fallback as record) as datetime =>
        let v = ScalarOf(parts)
        in
            if v is datetime then v
            else if v is text then
                (let t = try DateTime.From(Text.TrimEnd(v, {"Z"}))
                 in  if t[HasError] then FtDateTime(fallback) else t[Value])
            else FtDateTime(fallback),

    // EventData/Data name-value pairs; UserData unwraps its single carrier
    // element. Unnamed Data children become Data1..DataN; duplicate names get
    // a numeric suffix so the record can hold them all.
    EventDataRecord = (event as nullable record) as nullable record =>
        let
            holder0 = FirstChild(event, "EventData"),
            userDat = if holder0 = null then FirstChild(event, "UserData") else null,
            inner   = if userDat = null then null else FirstChild(userDat, null),
            holder  = if holder0 <> null then holder0
                      else if inner <> null then inner
                      else userDat
        in
            if holder = null then null
            else
                let
                    children = ChildElems(holder, null),
                    named = List.Accumulate(List.Positions(children),
                                [Used = [], Pairs = {}],
                                (st, i) =>
                        let
                            c    = children{i},
                            nm   = if c[Name] = "Data" then ScalarOf(AttrOf(c, "Name")) else null,
                            base = if nm <> null and nm <> "" then Text.From(nm)
                                   else if c[Name] <> "Data" then c[Name]
                                   else "Data" & Number.ToText(i + 1),
                            seen = Record.FieldOrDefault(st[Used], base, 0),
                            key  = if seen = 0 then base
                                   else base & Number.ToText(seen + 1)
                        in
                            [Used  = Record.RemoveFields(st[Used], {base}, MissingField.Ignore)
                                     & Record.FromList({seen + 1}, {base}),
                             Pairs = st[Pairs] & {{key, ElemScalar(c)}}])
                in
                    Record.FromList(List.Transform(named[Pairs], (p) => p{1}),
                                    List.Transform(named[Pairs], (p) => p{0})),

    ExtractRow = (rec as record) as list =>
        let
            items     = rec[Items],
            roots     = List.Select(items, (i) => i[Kind] = "elem"),
            top       = if List.IsEmpty(roots) then null else roots{0},
            isEvent   = top <> null and top[Name] = "Event",
            event     = if isEvent then top else null,
            system    = FirstChild(event, "System"),
            provider  = FirstChild(system, "Provider"),
            execution = FirstChild(system, "Execution"),
            security  = FirstChild(system, "Security"),
            timeCr    = FirstChild(system, "TimeCreated"),
            level     = AsInt(ElemScalar(FirstChild(system, "Level"))),
            levelName = if level <> null and level >= 0 and level < List.Count(LevelNames)
                        then LevelNames{level} else null
        in
            {rec[RecordId],
             TimeOf(AttrOf(timeCr, "SystemTime"), rec[Written]),
             ScalarOf(AttrOf(provider, "Name")),
             AsInt(ElemScalar(FirstChild(system, "EventID"))),
             level,
             levelName,
             AsInt(ElemScalar(FirstChild(system, "Task"))),
             AsInt(ElemScalar(FirstChild(system, "Opcode"))),
             KeywordsText(ElemScalar(FirstChild(system, "Keywords"))),
             ElemScalar(FirstChild(system, "Channel")),
             ElemScalar(FirstChild(system, "Computer")),
             AsInt(ScalarOf(AttrOf(execution, "ProcessID"))),
             AsInt(ScalarOf(AttrOf(execution, "ThreadID"))),
             ScalarOf(AttrOf(security, "UserID")),
             EventDataRecord(event),
             if OptIncludeXml then RecordXml(items) else null},

    //==================== output table ====================
    ColNames = {"RecordId", "TimeCreated", "Provider", "EventId", "Level", "LevelName",
                "Task", "Opcode", "Keywords", "Channel", "Computer", "ProcessId",
                "ThreadId", "UserId", "EventData", "Xml"},

    BaseTable = #table(ColNames, List.Transform(Records, ExtractRow)),
    Typed = Table.TransformColumnTypes(BaseTable,
        {{"RecordId", Int64.Type}, {"TimeCreated", type datetime},
         {"Provider", type text}, {"EventId", Int64.Type}, {"Level", Int64.Type},
         {"LevelName", type text}, {"Task", Int64.Type}, {"Opcode", Int64.Type},
         {"Keywords", type text}, {"Channel", type text}, {"Computer", type text},
         {"ProcessId", Int64.Type}, {"ThreadId", Int64.Type}, {"UserId", type text},
         {"Xml", type text}}),
    Result = if OptIncludeXml then Typed else Table.RemoveColumns(Typed, {"Xml"})
in
    Result meta [
        Evtx.Version            = Number.ToText(MajorVersion) & "." & Number.ToText(MinorVersion),
        Evtx.IsDirty            = IsDirty,
        Evtx.IsFull             = IsFull,
        Evtx.NextRecordId       = NextRecordId,
        Evtx.ChunkCount         = List.Count(ChunkBases),
        Evtx.DeclaredChunkCount = DeclaredChunks,
        Evtx.SkippedRecords     = Skipped
    ]
