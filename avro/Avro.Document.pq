// SPDX-License-Identifier: Apache-2.0
//
// Avro.Document.pq — read Apache Avro Object Container Files (OCF) in pure Power Query M.
// No Java, no Spark, no ODBC driver, no custom connector required.
// Paste into a blank query (name it Avro.Document), or wrap as a function in your PBIX / dataflow.
//
// Usage:
//   let
//       Avro.Document = <this expression>,
//       t = Avro.Document(File.Contents("C:\path\to\file.avro"))
//   in
//       t
//
//   // Event Hubs / IoT Hub Capture files: the Body bytes column is decoded as UTF-8
//   // text by default. To parse it as JSON instead:
//   //   Avro.Document(source, [ParseBodyAsJson = true])
//
// Options (optional second argument, all keys optional):
//   ParseBodyAsJson  logical, default false — parse a top-level `Body` bytes field with
//                    Json.Document (falls back to text when the payload isn't JSON,
//                    unless Strict = true).
//   KeepBodyBinary   logical, default false — leave `Body` as raw bytes.
//   Encoding         TextEncoding for the default Body-to-text decode, default Utf8.
//   MaxRows          number — stop after this many rows (later blocks are not decoded).
//   Strict           logical, default false — when true, malformed input that is normally
//                    tolerated becomes an error (non-JSON Body with ParseBodyAsJson,
//                    trailing bytes inside a data block).
//
// Supported: codecs null, deflate, snappy, zstandard; all primitive types; records,
//            enums, arrays, maps, unions, fixed; named type references incl. recursive
//            schemas; logical types decimal, date, time-millis/micros,
//            timestamp-millis/micros, local-timestamp-millis/micros, uuid, duration;
//            multi-block files; Event Hubs Capture Body unwrapping.
//            snappy and zstandard blocks are decompressed through the codec oracle
//            inlined below (a minimal in-memory Parquet file handed to Parquet.Document,
//            since Binary.Decompress exposes only deflate/gzip). A snappy block's
//            4-byte CRC-32 trailer is stripped before decoding, not validated.
// Not supported: codecs bzip2 and xz (clear error — the engine has no codec for them);
//            schema resolution against a reader schema (the writer schema embedded in
//            the file is used); single-object encoding and raw datum streams (OCF only).
// Precision: Avro longs beyond 2^53 lose precision (M numbers are doubles); the same
//            applies to decimals whose unscaled value exceeds 2^53.
// Output:    a table (one column per field of the top-level record, or a single
//            `Value` column for non-record schemas), with `Avro.Schema` and
//            `Avro.Codec` in the table metadata.

(source as binary, optional options as nullable record) as table =>
let
    bin   = Binary.Buffer(source),
    total = Binary.Length(bin),

    opts              = if options = null then [] else options,
    OptStrict         = Record.FieldOrDefault(opts, "Strict", false) = true,
    OptMaxRows        = Record.FieldOrDefault(opts, "MaxRows", null),
    OptParseBody      = Record.FieldOrDefault(opts, "ParseBodyAsJson", false) = true,
    OptKeepBodyBinary = Record.FieldOrDefault(opts, "KeepBodyBinary", false) = true,
    OptEncoding       = let e = Record.FieldOrDefault(opts, "Encoding", null)
                        in  if e = null then TextEncoding.Utf8 else e,

    //==================== low-level byte access ====================
    Slice = (b as binary, offset as number, count as number) as binary =>
        if count <= 0 then #binary({})
        else Binary.Range(b, offset, count),

    Byte = (off as number) as number => BinaryFormat.Byte(Binary.Range(bin, off, 1)),
    Hex  = (b as binary) as text => Text.Upper(Binary.ToText(b, BinaryEncoding.Hex)),

    UIntBEOf = (b as binary) as number =>
        List.Accumulate(Binary.ToList(b), 0, (s, c) => s * 256 + c),

    IntBEOf = (b as binary) as number =>              // two's complement, big-endian
        let n = Binary.Length(b),
            u = UIntBEOf(b)
        in  if n = 0 then 0
            else if u >= Number.Power(2, 8 * n - 1) then u - Number.Power(2, 8 * n)
            else u,

    // Avro varint: little-endian base-128, low 7 bits per byte, high bit = continuation.
    // Zigzag: 0,-1,1,-2,2,... — even unsigned values are non-negative, odd are negative.
    ZigZag = (u as number) as number =>
        if Number.Mod(u, 2) = 0 then u / 2 else -((u + 1) / 2),

    VarUIntAt = (off as number) as record =>          // [Value, Size], offset-based
        let f = (o as number, acc as number, scale as number, n as number) as record =>
                let b = Byte(o)
                in  if b < 128 then [Value = acc + b * scale, Size = n + 1]
                    else @f(o + 1, acc + (b - 128) * scale, scale * 128, n + 1)
        in  f(off, 0, 1, 0),

    VarLongAt = (off as number) as record =>          // zigzag-decoded [Value, Size]
        let v = VarUIntAt(off) in [Value = ZigZag(v[Value]), Size = v[Size]],

    //==================== file header ====================
    // magic "Obj" 0x01, then a map<string, bytes> of metadata, then a 16-byte sync marker
    MagicOk = total >= 4 and Hex(Slice(bin, 0, 4)) = "4F626A01",

    ReadPairsAt = (off as number, remaining as number, acc as list) as record =>
        if remaining = 0 then [Pairs = acc, Pos = off]
        else
            let k    = VarLongAt(off),
                kOff = off + k[Size],
                key  = Text.FromBinary(Slice(bin, kOff, k[Value]), TextEncoding.Utf8),
                v    = VarLongAt(kOff + k[Value]),
                vOff = kOff + k[Value] + v[Size],
                val  = Slice(bin, vOff, v[Value])
            in  @ReadPairsAt(vOff + v[Value], remaining - 1, acc & {[Key = key, Value = val]}),

    ReadMapAt = (off as number, acc as list) as record =>   // [Pairs, Pos]
        let n     = VarLongAt(off),
            after = off + n[Size]
        in
            if n[Value] = 0 then [Pairs = acc, Pos = after]
            else if n[Value] > 0 then
                let r = ReadPairsAt(after, n[Value], acc) in @ReadMapAt(r[Pos], r[Pairs])
            else                                            // negative count: block byte size precedes items
                let sz = VarLongAt(after),
                    r  = ReadPairsAt(after + sz[Size], -n[Value], acc)
                in  @ReadMapAt(r[Pos], r[Pairs]),

    hdr = if MagicOk then ReadMapAt(4, {})
          else error Error.Record("DataFormat.Error",
                   "Not an Avro Object Container File (bad magic bytes).",
                   [Expected = "4F626A01 (""Obj"" 0x01)",
                    Actual   = if total < 4 then "file shorter than 4 bytes" else Hex(Slice(bin, 0, 4))]),

    MetaLookup = (name as text) as nullable binary =>
        let hits = List.Select(hdr[Pairs], (p) => p[Key] = name)
        in  if List.IsEmpty(hits) then null else hits{0}[Value],

    SyncHex   = Hex(Slice(bin, hdr[Pos], 16)),
    DataStart = hdr[Pos] + 16,

    SchemaBytes = MetaLookup("avro.schema"),
    SchemaText  = if SchemaBytes = null
                  then error Error.Record("DataFormat.Error",
                           "File header has no avro.schema metadata entry.", null)
                  else Text.FromBinary(SchemaBytes, TextEncoding.Utf8),
    SchemaJson  = Json.Document(SchemaText),

    Codec = let c = MetaLookup("avro.codec")
            in  if c = null then "null" else Text.FromBinary(c, TextEncoding.Utf8),

    //==================== codec oracle (snappy / zstandard) ====================
    // Binary.Decompress implements only deflate and gzip, but the engine's Parquet
    // reader ships snappy, zstandard and more. CodecDecompress wraps a raw codec
    // stream in a minimal, spec-conformant Parquet file (one REQUIRED
    // FIXED_LEN_BYTE_ARRAY column, one row, PLAIN encoding, so the uncompressed
    // data page is exactly the payload) and lets Parquet.Document decompress it.
    // The repo's codec-oracle/Codec.Decompress.pq is the full, general version
    // (all seven Compression.Type members, size overrides, LZ4 framing options);
    // Avro uses only snappy and zstandard, so just those two — and the size
    // derivation each needs — are inlined here. See codec-oracle/README.md.
    CodecDecompress = (compressed as binary, compression as number) as binary =>
    let
        // parquet CompressionCodec enum: SNAPPY = 1, ZSTD = 6
        codecId = if compression = Compression.Snappy then 1 else 6,
        blobLen = Binary.Length(compressed),

        UVarint = (n as number) as list =>
            List.Generate(
                () => [v = n, emit = true],
                each [emit],
                each [v = Number.IntegerDivide([v], 128), emit = [v] >= 128],
                each if [v] < 128 then [v] else Number.Mod([v], 128) + 128
            ),
        Z = (n as number) as binary =>
            Binary.FromList(UVarint(if n >= 0 then 2 * n else -2 * n - 1)),
        UInt32LE = (n as number) as binary =>
            Binary.FromList({
                Number.Mod(n, 256),
                Number.Mod(Number.IntegerDivide(n, 256), 256),
                Number.Mod(Number.IntegerDivide(n, 65536), 256),
                Number.Mod(Number.IntegerDivide(n, 16777216), 256)
            }),

        // the wrapper must declare the decompressed size; each codec stores it:
        // snappy as a leading varint preamble, a zstd frame as Frame_Content_Size
        // in its header (always written by the one-shot compressors Avro uses).
        SnappyPreambleSize =
            let
                head = Binary.ToList(Binary.Range(compressed, 0, List.Min({5, blobLen}))),
                folded = List.Accumulate(head, [value = 0, shift = 0, done = false],
                    (s, b) =>
                        if s[done] then s
                        else [
                            value = s[value] + Number.BitwiseShiftLeft(Number.BitwiseAnd(b, 127), s[shift]),
                            shift = s[shift] + 7,
                            done = b < 128
                        ])
            in
                if folded[done] then folded[value]
                else error Error.Record("DataFormat.Error", "Not a raw snappy stream: unterminated preamble varint"),
        ZstdContentSize =
            let
                head = List.FirstN(
                    Binary.ToList(Binary.Range(compressed, 0, List.Min({18, blobLen}))) & List.Repeat({0}, 18), 18),
                magicOk = head{0} = 0x28 and head{1} = 0xB5 and head{2} = 0x2F and head{3} = 0xFD,
                fhd = head{4},
                fcsFlag = Number.BitwiseShiftRight(fhd, 6),
                singleSegment = Number.BitwiseAnd(Number.BitwiseShiftRight(fhd, 5), 1),
                didLen = {0, 1, 2, 4}{Number.BitwiseAnd(fhd, 3)},
                pos = 5 + (if singleSegment = 1 then 0 else 1) + didLen
            in
                if not magicOk then
                    error Error.Record("DataFormat.Error", "Not a zstd frame (bad magic)")
                else if fcsFlag = 0 then
                    (if singleSegment = 1 then head{pos}
                     else error Error.Record("DataFormat.Error",
                        "This zstd frame does not declare its content size"))
                else if fcsFlag = 1 then head{pos} + head{pos + 1} * 256 + 256
                else if fcsFlag = 2 then
                    head{pos} + head{pos + 1} * 256 + head{pos + 2} * 65536 + head{pos + 3} * 16777216
                else
                    List.Accumulate({0, 1, 2, 3, 4, 5, 6, 7}, 0,
                        (s, i) => s + head{pos + i} * Number.Power(256, i)),
        usize =
            if compression = Compression.Snappy then SnappyPreambleSize else ZstdContentSize,

        PageHeader = Binary.Combine({
            #binary({0x15}), Z(0),
            #binary({0x15}), Z(usize),
            #binary({0x15}), Z(blobLen),
            #binary({0x2C}),
                #binary({0x15}), Z(1),
                #binary({0x15}), Z(0),
                #binary({0x15}), Z(3),
                #binary({0x15}), Z(3),
                #binary({0x00}),
            #binary({0x00})
        }),
        phLen = Binary.Length(PageHeader),

        SchemaRoot = Binary.Combine({
            #binary({0x48, 0x06}), Text.ToBinary("schema"),
            #binary({0x15}), Z(1),
            #binary({0x00})
        }),
        SchemaCol = Binary.Combine({
            #binary({0x15}), Z(7),
            #binary({0x15}), Z(usize),
            #binary({0x15}), Z(0),
            #binary({0x18, 0x07}), Text.ToBinary("payload"),
            #binary({0x00})
        }),
        ColumnMetaData = Binary.Combine({
            #binary({0x15}), Z(7),
            #binary({0x19, 0x25}), Z(0), Z(3),
            #binary({0x19, 0x18, 0x07}), Text.ToBinary("payload"),
            #binary({0x15}), Z(codecId),
            #binary({0x16}), Z(1),
            #binary({0x16}), Z(phLen + usize),
            #binary({0x16}), Z(phLen + blobLen),
            #binary({0x26}), Z(4),
            #binary({0x00})
        }),
        ColumnChunk = Binary.Combine({
            #binary({0x26}), Z(4),
            #binary({0x1C}), ColumnMetaData,
            #binary({0x00})
        }),
        RowGroup = Binary.Combine({
            #binary({0x19, 0x1C}), ColumnChunk,
            #binary({0x16}), Z(phLen + blobLen),
            #binary({0x16}), Z(1),
            #binary({0x00})
        }),
        createdBy = Text.ToBinary("powerquery-driverless codec oracle"),
        FileMetaData = Binary.Combine({
            #binary({0x15}), Z(1),
            #binary({0x19, 0x2C}), SchemaRoot, SchemaCol,
            #binary({0x16}), Z(1),
            #binary({0x19, 0x1C}), RowGroup,
            #binary({0x28}), Binary.FromList(UVarint(Binary.Length(createdBy))), createdBy,
            #binary({0x00})
        }),

        Wrapper = Binary.Combine({
            Text.ToBinary("PAR1"),
            PageHeader,
            compressed,
            FileMetaData,
            UInt32LE(Binary.Length(FileMetaData)),
            Text.ToBinary("PAR1")
        }),

        // Parquet.Document needs a random-access binary; Binary.Combine over a
        // streamed input yields a streamed one, hence the Binary.Buffer.
        result = Parquet.Document(Binary.Buffer(Wrapper)){0}[payload]
    in
        result,

    // Avro codec dispatch. null/deflate are native (Binary.Decompress); snappy and
    // zstandard route through the oracle above. An Avro snappy block is a raw snappy
    // stream followed by a 4-byte big-endian CRC-32 of the uncompressed data; those
    // trailing bytes are not part of the snappy stream, so they are dropped before
    // decoding. The CRC itself is not validated — the per-block sync marker already
    // catches corruption.
    Inflate =
        if Codec = "null" then (b as binary) as binary => b
        else if Codec = "deflate" then (b as binary) as binary => Binary.Decompress(b, Compression.Deflate)
        else if Codec = "snappy" then (b as binary) as binary =>
            let n = Binary.Length(b)
            in  if n < 4 then
                    error Error.Record("DataFormat.Error",
                        "Corrupt Avro snappy block: shorter than its 4-byte CRC-32 trailer.", [BlockBytes = n])
                else CodecDecompress(Binary.Range(b, 0, n - 4), Compression.Snappy)
        else if Codec = "zstandard" then (b as binary) as binary => CodecDecompress(b, Compression.Zstandard)
        else error Error.Record("DataFormat.Error",
                 "Unsupported Avro codec """ & Codec & """. Supported codecs: null, deflate, snappy, zstandard "
                     & "(bzip2 and xz have no engine codec and are not supported).",
                 [Codec = Codec]),

    //==================== schema: named types ====================
    // [FullName, ChildNs]: a dotted name attribute overrides the namespace attribute,
    // which overrides the enclosing namespace.
    NameOf = (schema as record, enclosingNs as nullable text) as record =>
        let name = Record.Field(schema, "name"),
            ns0  = Record.FieldOrDefault(schema, "namespace", enclosingNs)
        in
            if Text.Contains(name, ".") then
                [FullName = name,
                 ChildNs  = Text.BeforeDelimiter(name, ".", {0, RelativePosition.FromEnd})]
            else
                [FullName = if ns0 = null or ns0 = "" then name else ns0 & "." & name,
                 ChildNs  = ns0],

    CollectNamed = (schema as any, ns as nullable text) as list =>   // list of [Name, Schema, Ns]
        if schema is list then
            List.Combine(List.Transform(schema, (s) => @CollectNamed(s, ns)))
        else if schema is record then
            let t = Record.FieldOrDefault(schema, "type")
            in
                if t is record or t is list then @CollectNamed(t, ns)
                else if t = "record" or t = "error" then
                    let nm    = NameOf(schema, ns),
                        inner = List.Combine(List.Transform(
                                    Record.FieldOrDefault(schema, "fields", {}),
                                    (f) => @CollectNamed(f[type], nm[ChildNs])))
                    in  {[Name = nm[FullName], Schema = schema, Ns = nm[ChildNs]]} & inner
                else if t = "enum" or t = "fixed" then
                    let nm = NameOf(schema, ns)
                    in  {[Name = nm[FullName], Schema = schema, Ns = nm[ChildNs]]}
                else if t = "array" then @CollectNamed(Record.FieldOrDefault(schema, "items"), ns)
                else if t = "map" then @CollectNamed(Record.FieldOrDefault(schema, "values"), ns)
                else {}
        else {},

    NamedDefs  = List.Distinct(CollectNamed(SchemaJson, null), each [Name]),
    NamedNames = List.Transform(NamedDefs, (d) => d[Name]),
    NamedFormats = Record.FromList(
        List.Transform(NamedDefs, (d) => FormatFor(d[Schema], d[Ns])),
        NamedNames),

    ResolveRefName = (name as text, ns as nullable text) as text =>
        if Text.Contains(name, ".") then name
        else if ns <> null and List.Contains(NamedNames, ns & "." & name) then ns & "." & name
        else name,

    // Deferred lookup so that recursive schemas (a record referencing itself) can be
    // compiled without infinite recursion: the reference is only resolved at parse time.
    RefFormat = (name as text, ns as nullable text) as function =>
        let resolved = ResolveRefName(name, ns)
        in  BinaryFormat.Choice(BinaryFormat.Null, (x) =>
                if List.Contains(NamedNames, resolved) then Record.Field(NamedFormats, resolved)
                else error Error.Record("DataFormat.Error",
                         "Unknown named type reference """ & name & """ in schema.",
                         [ResolvedAs = resolved, Known = NamedNames])),

    //==================== datum binary formats ====================
    VarUIntFmt = BinaryFormat.Transform(
        BinaryFormat.List(BinaryFormat.Byte, (b) => b >= 128),   // read while continuation bit set
        (bytes) => List.Accumulate(bytes, [v = 0, s = 1],
                       (st, b) => [v = st[v] + (if b >= 128 then b - 128 else b) * st[s],
                                   s = st[s] * 128])[v]),
    LongFmt   = BinaryFormat.Transform(VarUIntFmt, ZigZag),
    BoolFmt   = BinaryFormat.Transform(BinaryFormat.Byte, (b) => b <> 0),
    FloatFmt  = BinaryFormat.ByteOrder(BinaryFormat.Single, ByteOrder.LittleEndian),
    DoubleFmt = BinaryFormat.ByteOrder(BinaryFormat.Double, ByteOrder.LittleEndian),

    BinFixed  = (len as number) as function =>
        if len = 0 then BinaryFormat.Transform(BinaryFormat.Null, (x) => #binary({}))
        else BinaryFormat.Binary(len),

    BytesFmt  = BinaryFormat.Choice(LongFmt, (len) => BinFixed(len)),
    StringFmt = BinaryFormat.Choice(LongFmt, (len) =>
                    BinaryFormat.Transform(BinFixed(len), (b) => Text.FromBinary(b, TextEncoding.Utf8))),

    PrimitiveFmt = (t as text) as nullable function =>
        if t = "null" then BinaryFormat.Null
        else if t = "boolean" then BoolFmt
        else if t = "int" or t = "long" then LongFmt
        else if t = "float" then FloatFmt
        else if t = "double" then DoubleFmt
        else if t = "bytes" then BytesFmt
        else if t = "string" then StringFmt
        else null,

    // Arrays and maps share Avro's blocked encoding: repeated (count, items...) groups,
    // negative count = absolute count preceded by the block's byte size, 0 = end.
    BlockedFmt = (itemFmt as function, finish as function) as function =>
        let loop = (acc as list) as function =>
            BinaryFormat.Choice(LongFmt, (n) =>
                if n = 0 then BinaryFormat.Transform(BinaryFormat.Null, (x) => finish(acc))
                else if n > 0 then
                    BinaryFormat.Choice(BinaryFormat.List(itemFmt, n), (items) => @loop(acc & items))
                else
                    BinaryFormat.Choice(LongFmt, (size) =>
                        BinaryFormat.Choice(BinaryFormat.List(itemFmt, -n), (items) => @loop(acc & items))))
        in  loop({}),

    ArrayFmtFor = (itemFmt as function) as function => BlockedFmt(itemFmt, (items) => items),

    MapFmtFor = (valFmt as function) as function =>
        BlockedFmt(
            BinaryFormat.Record([Key = StringFmt, Value = valFmt]),
            (pairs) =>
                let keys = List.Transform(pairs, (p) => p[Key])
                in  if List.Count(List.Distinct(keys)) <> List.Count(keys)
                    then error Error.Record("DataFormat.Error", "Duplicate keys in Avro map.", [Keys = keys])
                    else Record.FromList(List.Transform(pairs, (p) => p[Value]), keys)),

    //==================== logical types ====================
    EpochDate = #date(1970, 1, 1),
    EpochDtz  = #datetimezone(1970, 1, 1, 0, 0, 0, 0, 0),
    EpochDt   = #datetime(1970, 1, 1, 0, 0, 0),
    Midnight  = #time(0, 0, 0),

    LE4 = (bytes as list, i as number) as number =>
        bytes{i} + bytes{i + 1} * 256 + bytes{i + 2} * 65536 + bytes{i + 3} * 16777216,

    // Unknown logical types fall back to the base type, per the Avro spec. uuid needs
    // no handling — its base type is string.
    ApplyLogical = (baseFmt as function, schema as record, baseType as text) as function =>
        let lt = Record.FieldOrDefault(schema, "logicalType")
        in
            if lt = null then baseFmt
            else if lt = "decimal" and (baseType = "bytes" or baseType = "fixed") then
                let scale = Record.FieldOrDefault(schema, "scale", 0)
                in  BinaryFormat.Transform(baseFmt, (b) => IntBEOf(b) / Number.Power(10, scale))
            else if lt = "date" and baseType = "int" then
                BinaryFormat.Transform(baseFmt, (d) => Date.AddDays(EpochDate, d))
            else if lt = "time-millis" and baseType = "int" then
                BinaryFormat.Transform(baseFmt, (t) => Midnight + #duration(0, 0, 0, t / 1000))
            else if lt = "time-micros" and baseType = "long" then
                BinaryFormat.Transform(baseFmt, (t) => Midnight + #duration(0, 0, 0, t / 1000000))
            else if lt = "timestamp-millis" and baseType = "long" then
                BinaryFormat.Transform(baseFmt, (t) => EpochDtz + #duration(0, 0, 0, t / 1000))
            else if lt = "timestamp-micros" and baseType = "long" then
                BinaryFormat.Transform(baseFmt, (t) => EpochDtz + #duration(0, 0, 0, t / 1000000))
            else if lt = "local-timestamp-millis" and baseType = "long" then
                BinaryFormat.Transform(baseFmt, (t) => EpochDt + #duration(0, 0, 0, t / 1000))
            else if lt = "local-timestamp-micros" and baseType = "long" then
                BinaryFormat.Transform(baseFmt, (t) => EpochDt + #duration(0, 0, 0, t / 1000000))
            else if lt = "duration" and baseType = "fixed" then
                BinaryFormat.Transform(baseFmt, (b) =>
                    let l = Binary.ToList(b)
                    in  [Months = LE4(l, 0), Days = LE4(l, 4), Milliseconds = LE4(l, 8)])
            else baseFmt,

    //==================== schema -> format compiler ====================
    FormatFor = (schema as any, ns as nullable text) as function =>
        if schema is text then
            let p = PrimitiveFmt(schema)
            in  if p <> null then p else RefFormat(schema, ns)
        else if schema is list then                             // union: zigzag branch index
            let branches = List.Transform(schema, (s) => @FormatFor(s, ns)),
                n        = List.Count(branches)
            in  BinaryFormat.Choice(LongFmt, (i) =>
                    if i >= 0 and i < n then branches{i}
                    else error Error.Record("DataFormat.Error",
                             "Union branch index out of range.", [Index = i, BranchCount = n]))
        else if schema is record then
            let t = Record.FieldOrDefault(schema, "type")
            in
                if t is record or t is list then @FormatFor(t, ns)
                else if t = "record" or t = "error" then
                    let nm     = NameOf(schema, ns),
                        fields = Record.FieldOrDefault(schema, "fields", {}),
                        names  = List.Transform(fields, (f) => f[name]),
                        fmts   = List.Transform(fields, (f) => @FormatFor(f[type], nm[ChildNs]))
                    in  BinaryFormat.Record(Record.FromList(fmts, names))
                else if t = "enum" then
                    let symbols = Record.FieldOrDefault(schema, "symbols", {}),
                        n       = List.Count(symbols)
                    in  BinaryFormat.Transform(LongFmt, (i) =>
                            if i >= 0 and i < n then symbols{i}
                            else error Error.Record("DataFormat.Error",
                                     "Enum index out of range.", [Index = i, Symbols = symbols]))
                else if t = "array" then ArrayFmtFor(@FormatFor(Record.Field(schema, "items"), ns))
                else if t = "map" then MapFmtFor(@FormatFor(Record.Field(schema, "values"), ns))
                else if t = "fixed" then ApplyLogical(BinFixed(Record.Field(schema, "size")), schema, "fixed")
                else if t is text and PrimitiveFmt(t) <> null then ApplyLogical(PrimitiveFmt(t), schema, t)
                else if t is text then RefFormat(t, ns)         // named reference as [type = "Name"]
                else error Error.Record("DataFormat.Error", "Invalid Avro schema node.", [Node = schema])
        else error Error.Record("DataFormat.Error", "Invalid Avro schema node.", [Node = schema]),

    TopFmt = FormatFor(SchemaJson, null),

    //==================== data blocks ====================
    // block = (object count, byte size, serialized data, 16-byte sync marker)
    BlockAt = (off as number) as record =>
        let cnt     = VarLongAt(off),
            sz      = VarLongAt(off + cnt[Size]),
            dataOff = off + cnt[Size] + sz[Size],
            next    = dataOff + sz[Value] + 16
        in
            if next > total then
                error Error.Record("DataFormat.Error",
                    "Truncated Avro file: data block extends past end of file.",
                    [BlockOffset = off, DeclaredSize = sz[Value], FileSize = total])
            else [Count = cnt[Value], DataOffset = dataOff, DataSize = sz[Value],
                  Sync = Slice(bin, dataOff + sz[Value], 16), Next = next],

    Blocks = List.Generate(
        () => if DataStart >= total then null else BlockAt(DataStart),
        (b) => b <> null,
        (b) => if b[Next] >= total then null else BlockAt(b[Next])),

    DecodeBlock = (b as record) as list =>
        let raw = if Hex(b[Sync]) = SyncHex
                  then Slice(bin, b[DataOffset], b[DataSize])
                  else error Error.Record("DataFormat.Error",
                           "Sync marker mismatch — the file is corrupt.",
                           [BlockOffset = b[DataOffset], Expected = SyncHex, Actual = Hex(b[Sync])]),
            data = Binary.Buffer(Inflate(raw))
        in
            if OptStrict then
                let parsed = BinaryFormat.Record([
                        Items = BinaryFormat.List(TopFmt, b[Count]),
                        Rest  = BinaryFormat.List(BinaryFormat.Byte)
                    ])(data)
                in  if List.IsEmpty(parsed[Rest]) then parsed[Items]
                    else error Error.Record("DataFormat.Error",
                             "Data block has trailing bytes after the declared object count.",
                             [BlockOffset = b[DataOffset], TrailingBytes = List.Count(parsed[Rest])])
            else BinaryFormat.List(TopFmt, b[Count])(data),

    AllRows = List.Combine(List.Transform(Blocks, DecodeBlock)),
    Rows    = if OptMaxRows = null then AllRows else List.FirstN(AllRows, OptMaxRows),

    //==================== table shaping ====================
    ResolveSchema = (schema as any, ns as nullable text) as any =>
        if schema is text and PrimitiveFmt(schema) = null then
            let resolved = ResolveRefName(schema, ns),
                hits     = List.Select(NamedDefs, (d) => d[Name] = resolved)
            in  if List.IsEmpty(hits) then schema else hits{0}[Schema]
        else schema,

    // Unwrap unions with exactly one non-null branch (the nullable-X idiom); null for
    // anything without a single static shape.
    EffSchema = (schema as any, ns as nullable text) as any =>
        if schema is list then
            let nn = List.Select(schema, (s) => not (s is text and s = "null"))
            in  if List.Count(nn) = 1 then @EffSchema(nn{0}, ns) else null
        else ResolveSchema(schema, ns),

    PrimTypeOf = (t as text) as nullable type =>
        if t = "boolean" then type nullable logical
        else if t = "int" or t = "long" then Int64.Type
        else if t = "float" or t = "double" then type nullable number
        else if t = "string" then type nullable text
        else if t = "bytes" then type nullable binary
        else null,

    MTypeFor = (schema as any, ns as nullable text) as nullable type =>
        let s = EffSchema(schema, ns)
        in
            if s = null then null
            else if s is text then PrimTypeOf(s)
            else if s is record then
                let t  = Record.FieldOrDefault(s, "type"),
                    lt = Record.FieldOrDefault(s, "logicalType")
                in
                    if t is record or t is list then @MTypeFor(t, ns)
                    else if lt = "date" then type nullable date
                    else if lt = "time-millis" or lt = "time-micros" then type nullable time
                    else if lt = "timestamp-millis" or lt = "timestamp-micros" then type nullable datetimezone
                    else if lt = "local-timestamp-millis" or lt = "local-timestamp-micros" then type nullable datetime
                    else if lt = "decimal" then type nullable number
                    else if lt = "duration" then null
                    else if t = "enum" then type nullable text
                    else if t = "fixed" then type nullable binary
                    else if t = "record" or t = "error" or t = "array" or t = "map" then null
                    else if t is text then PrimTypeOf(t)
                    else null
            else null,

    TopSchema   = ResolveSchema(SchemaJson, null),
    TopIsRecord = TopSchema is record and
                  (let t = Record.FieldOrDefault(TopSchema, "type") in t = "record" or t = "error"),
    TopChildNs  = if TopIsRecord then NameOf(TopSchema, null)[ChildNs] else null,
    FieldList   = if TopIsRecord then Record.FieldOrDefault(TopSchema, "fields", {}) else {},
    ColNames    = if TopIsRecord then List.Transform(FieldList, (f) => f[name]) else {"Value"},

    BaseTable = #table(ColNames,
        List.Transform(Rows, (r) => if TopIsRecord then Record.ToList(r) else {r})),

    TypePairs = if TopIsRecord
                then List.Select(
                         List.Transform(FieldList, (f) => {f[name], MTypeFor(f[type], TopChildNs)}),
                         (p) => p{1} <> null)
                else let vt = MTypeFor(SchemaJson, null)
                     in  if vt = null then {} else {{"Value", vt}},
    Typed = if List.IsEmpty(TypePairs) then BaseTable
            else Table.TransformColumnTypes(BaseTable, TypePairs),

    //==================== Event Hubs Capture friendly path ====================
    // Capture files carry the payload as a Body field of type bytes (usually JSON).
    // Default: decode Body to text. ParseBodyAsJson = true: parse it with Json.Document.
    // KeepBodyBinary = true: leave the raw bytes alone.
    BodyFields  = List.Select(FieldList, (f) => f[name] = "Body"),
    BodyIsBytes = not List.IsEmpty(BodyFields) and
                  (let s = EffSchema(BodyFields{0}[type], TopChildNs)
                   in  (s is text and s = "bytes") or
                       (s is record and Record.FieldOrDefault(s, "type") = "bytes"
                                    and Record.FieldOrDefault(s, "logicalType") = null)),

    WithBody =
        if not TopIsRecord or OptKeepBodyBinary or not BodyIsBytes then Typed
        else if OptParseBody then
            Table.TransformColumns(Typed, {{"Body",
                (b) => if b = null then null
                       else if OptStrict then Json.Document(b)
                       else (try Json.Document(b) otherwise Text.FromBinary(b, OptEncoding)),
                type any}})
        else
            Table.TransformColumns(Typed, {{"Body",
                (b) => if b = null then null else Text.FromBinary(b, OptEncoding),
                type nullable text}})
in
    WithBody meta [Avro.Schema = SchemaText, Avro.Codec = Codec]
