// Codec.Decompress - decompress Snappy/Brotli/Zstd/LZ4/GZip/Deflate streams in
// pure M. Drop-in superset of Binary.Decompress: same (binary, Compression.Type)
// argument convention, e.g. Codec.Decompress(blob, Compression.Snappy).
//
// Binary.Decompress only implements GZip and Deflate, but the engine's Parquet
// reader ships the rest (probed 2026-07-17, 13/13 fixtures OK in PBI Desktop).
// For codecs Binary.Decompress refuses, this wraps the stream in a minimal
// single-cell Parquet file (one REQUIRED FIXED_LEN_BYTE_ARRAY column, one row,
// PLAIN encoding, so the uncompressed data page is exactly the payload) and
// lets Parquet.Document do the decompression. GZip and Deflate are routed to
// Binary.Decompress natively; Compression.None returns the input unchanged.
//
// The decompressed size the wrapper must declare is derived from the stream
// itself: Snappy preamble varint, GZip ISIZE trailer, hadoop-LZ4 big-endian
// header, zstd Frame_Content_Size, brotli first meta-block MLEN, and for raw
// LZ4 blocks a token walk over the sequences (no decompression, cost is one
// scan of the stream). Pass uncompressedSize explicitly to override, or where
// the stream genuinely does not say: a zstd frame written without content
// size, or a brotli stream the encoder split into several meta-blocks (large
// inputs). A wrong size always fails the Parquet read loudly; it can never
// return wrong bytes silently.
// options:
//   LZ4Framing    = "Auto" (default: the 8-byte hadoop size header is detected
//                   from the stream itself), or "Raw" / "Hadoop" to force a
//                   framing (parquet codec LZ4_RAW = 7 / legacy LZ4 = 5)
//   ReturnWrapper = true returns the wrapper bytes instead of parsing, for
//                   byte-level debugging against the B_*.parquet fixtures
//
// SPDX-License-Identifier: Apache-2.0
let
    Codec.Decompress = (compressed as binary, compression as number, optional uncompressedSize as nullable number, optional options as nullable record) as binary =>
    let
        opts = options ?? [],
        returnWrapper = Record.FieldOrDefault(opts, "ReturnWrapper", false) = true,
        lz4Framing = Text.Lower(Text.From(Record.FieldOrDefault(opts, "LZ4Framing", "Auto"))),
        // hadoop framing detection: bytes 4-7 big-endian hold the compressed
        // size, which for a single-chunk stream equals blobLen - 8 (the same
        // heuristic Arrow's Lz4HadoopCodec applies)
        lz4HadoopDetected =
            blobLen >= 9 and
            (let h = Binary.ToList(Binary.Range(compressed, 4, 4))
             in h{0} * 16777216 + h{1} * 65536 + h{2} * 256 + h{3} = blobLen - 8),
        lz4IsHadoop =
            if lz4Framing = "auto" then lz4HadoopDetected
            else if lz4Framing = "hadoop" then true
            else if lz4Framing = "raw" then false
            else error Error.Record("DataFormat.Error",
                "options[LZ4Framing] must be ""Auto"", ""Raw"" or ""Hadoop"""),

        // ---- Compression.Type -> parquet CompressionCodec enum --------------
        codecId =
            if compression = Compression.None then 0
            else if compression = Compression.Snappy then 1
            else if compression = Compression.GZip then 2
            else if compression = Compression.Brotli then 4
            else if compression = Compression.LZ4 then (if lz4IsHadoop then 5 else 7)
            else if compression = Compression.Zstandard then 6
            else if compression = Compression.Deflate then
                error Error.Record("DataFormat.Error",
                    "Parquet has no raw-deflate codec; Deflate is served by Binary.Decompress directly")
            else
                error Error.Record("DataFormat.Error",
                    "Unsupported Compression.Type value: " & Number.ToText(compression)),

        // ---- byte helpers ----------------------------------------------------
        // unsigned LEB128 varint as a byte list
        UVarint = (n as number) as list =>
            List.Generate(
                () => [v = n, emit = true],
                each [emit],
                each [v = Number.IntegerDivide([v], 128), emit = [v] >= 128],
                each if [v] < 128 then [v] else Number.Mod([v], 128) + 128
            ),
        // thrift compact protocol zigzag varint as binary
        Z = (n as number) as binary =>
            Binary.FromList(UVarint(if n >= 0 then 2 * n else -2 * n - 1)),
        UInt32LE = (n as number) as binary =>
            Binary.FromList({
                Number.Mod(n, 256),
                Number.Mod(Number.IntegerDivide(n, 256), 256),
                Number.Mod(Number.IntegerDivide(n, 65536), 256),
                Number.Mod(Number.IntegerDivide(n, 16777216), 256)
            }),

        // ---- uncompressed size: given, or derived from the stream -----------
        blobLen = Binary.Length(compressed),
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
        GZipTrailerSize =
            let tail = Binary.ToList(Binary.Range(compressed, blobLen - 4, 4))
            in tail{0} + tail{1} * 256 + tail{2} * 65536 + tail{3} * 16777216,
        LZ4HadoopHeaderSize =
            let head = Binary.ToList(Binary.Range(compressed, 0, 4))
            in head{3} + head{2} * 256 + head{1} * 65536 + head{0} * 16777216,
        // zstd Frame_Content_Size (RFC 8878 frame header); optional in the
        // format, but one-shot compressors normally write it
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
                        "This zstd frame does not declare its content size; pass uncompressedSize explicitly"))
                else if fcsFlag = 1 then head{pos} + head{pos + 1} * 256 + 256
                else if fcsFlag = 2 then
                    head{pos} + head{pos + 1} * 256 + head{pos + 2} * 65536 + head{pos + 3} * 16777216
                else
                    List.Accumulate({0, 1, 2, 3, 4, 5, 6, 7}, 0,
                        (s, i) => s + head{pos + i} * Number.Power(256, i)),
        // brotli first meta-block MLEN (RFC 7932 9.1-9.2, bits LSB-first);
        // exact for single-data-block streams, which is every stream the
        // encoder did not split; a split stream fails the read loudly
        BrotliFirstBlockSize =
            let
                head = List.FirstN(
                    Binary.ToList(Binary.Range(compressed, 0, List.Min({8, blobLen}))) & List.Repeat({0}, 8), 8),
                Bit = (i as number) as number =>
                    Number.BitwiseAnd(Number.BitwiseShiftRight(head{Number.IntegerDivide(i, 8)}, Number.Mod(i, 8)), 1),
                Bits = (pos as number, n as number) as number =>
                    List.Accumulate(List.Numbers(0, n), 0, (s, k) => s + Number.BitwiseShiftLeft(Bit(pos + k), k)),
                // WBITS: only its bit-length matters here (1, 4 or 7 bits)
                wbitsLen = if Bit(0) = 0 then 1 else if Bits(1, 3) <> 0 then 4 else 7,
                isLast = Bit(wbitsLen),
                p = if isLast = 1 then wbitsLen + 2 else wbitsLen + 1,
                nibCode = Bits(p, 2)
            in
                if isLast = 1 and Bit(wbitsLen + 1) = 1 then 0  // ISLASTEMPTY: empty stream
                else if nibCode = 3 then
                    error Error.Record("DataFormat.Error",
                        "Brotli stream opens with a metadata meta-block; pass uncompressedSize explicitly")
                else Bits(p + 2, 4 * (4 + nibCode)) + 1,
        // raw LZ4 block: the size is not stored, but a walk over the sequence
        // tokens (skipping literal runs, summing literal + match lengths)
        // derives it without decompressing
        LZ4RawWalkSize =
            let
                bytes = List.Buffer(Binary.ToList(compressed)),
                ExtRead = (start as number) as record =>
                    let ffs = List.Generate(() => start, (p) => bytes{p} = 255, (p) => p + 1)
                    in [count = List.Count(ffs), last = start + List.Count(ffs)],
                Step = (s as record) as record =>
                    if s[pos] >= blobLen then [pos = s[pos], total = s[total], phase = 1]
                    else
                        let
                            token = bytes{s[pos]},
                            litNib = Number.BitwiseShiftRight(token, 4),
                            matchNib = Number.BitwiseAnd(token, 15),
                            litInfo =
                                if litNib < 15 then [len = litNib, next = s[pos] + 1]
                                else let e = ExtRead(s[pos] + 1)
                                     in [len = 15 + 255 * e[count] + bytes{e[last]}, next = e[last] + 1],
                            afterLit = litInfo[next] + litInfo[len],
                            totalLit = s[total] + litInfo[len]
                        in
                            if afterLit >= blobLen then [pos = afterLit, total = totalLit, phase = 1]
                            else
                                let
                                    matchInfo =
                                        if matchNib < 15 then [len = matchNib + 4, next = afterLit + 2]
                                        else let e = ExtRead(afterLit + 2)
                                             in [len = 19 + 255 * e[count] + bytes{e[last]}, next = e[last] + 1]
                                in [pos = matchInfo[next], total = totalLit + matchInfo[len], phase = 0],
                states = List.Generate(
                    () => [pos = 0, total = 0, phase = 0],
                    (s) => s[phase] < 2,
                    (s) => if s[phase] = 1 then [pos = s[pos], total = s[total], phase = 2] else Step(s)
                )
            in
                List.Last(states)[total],
        usize =
            if uncompressedSize <> null then uncompressedSize
            else if compression = Compression.None then blobLen
            else if compression = Compression.Snappy then SnappyPreambleSize
            else if compression = Compression.GZip then GZipTrailerSize
            else if compression = Compression.Brotli then BrotliFirstBlockSize
            else if compression = Compression.Zstandard then ZstdContentSize
            else if compression = Compression.LZ4 then
                (if lz4IsHadoop then LZ4HadoopHeaderSize else LZ4RawWalkSize)
            else error Error.Record("DataFormat.Error",
                "No size derivation for this Compression.Type; pass uncompressedSize explicitly"),

        // ---- thrift compact structures (field-header bytes hardcoded) -------
        // PageHeader { 1: type, 2: uncompressed_page_size, 3: compressed_page_size,
        //              5: DataPageHeader { num_values, PLAIN, RLE, RLE } }
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

        // SchemaElement root { 4: name = "schema", 5: num_children = 1 }
        SchemaRoot = Binary.Combine({
            #binary({0x48, 0x06}), Text.ToBinary("schema"),
            #binary({0x15}), Z(1),
            #binary({0x00})
        }),
        // SchemaElement column { 1: FIXED_LEN_BYTE_ARRAY, 2: type_length,
        //                        3: REQUIRED, 4: name = "payload" }
        SchemaCol = Binary.Combine({
            #binary({0x15}), Z(7),
            #binary({0x15}), Z(usize),
            #binary({0x15}), Z(0),
            #binary({0x18, 0x07}), Text.ToBinary("payload"),
            #binary({0x00})
        }),
        // ColumnMetaData { 1: type, 2: encodings [PLAIN, RLE], 3: path ["payload"],
        //                  4: codec, 5: num_values, 6: total_uncompressed_size,
        //                  7: total_compressed_size, 9: data_page_offset }
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
        // ColumnChunk { 2: file_offset = 4, 3: meta_data }
        ColumnChunk = Binary.Combine({
            #binary({0x26}), Z(4),
            #binary({0x1C}), ColumnMetaData,
            #binary({0x00})
        }),
        // RowGroup { 1: columns, 2: total_byte_size, 3: num_rows = 1 }
        RowGroup = Binary.Combine({
            #binary({0x19, 0x1C}), ColumnChunk,
            #binary({0x16}), Z(phLen + blobLen),
            #binary({0x16}), Z(1),
            #binary({0x00})
        }),
        createdBy = Text.ToBinary("powerquery-driverless codec oracle"),
        // FileMetaData { 1: version, 2: schema, 3: num_rows, 4: row_groups, 6: created_by }
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

        // ---- run -------------------------------------------------------------
        // native shortcuts where the engine exposes the codec directly; the
        // oracle path propagates any engine error as-is (unsupported codec,
        // malformed stream) - the message is the probe's most valuable output.
        // Parquet.Document requires a random-access binary, and Binary.Combine
        // over a streamed input (e.g. File.Contents) yields a streamed one,
        // hence the Binary.Buffer.
        result =
            if returnWrapper then Wrapper
            else if compression = Compression.None then compressed
            else if compression = Compression.GZip or compression = Compression.Deflate then
                Binary.Decompress(compressed, compression)
            else
                Parquet.Document(Binary.Buffer(Wrapper)){0}[payload]
    in
        result
in
    Codec.Decompress
