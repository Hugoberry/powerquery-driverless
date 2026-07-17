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
// uncompressedSize is required for Brotli, Zstandard and raw LZ4; it is derived
// from the stream for Snappy (preamble varint), GZip (ISIZE trailer) and
// hadoop-framed LZ4 (big-endian header).
// options:
//   LZ4Framing    = "Raw" (default, parquet LZ4_RAW) or "Hadoop" (legacy codec 5)
//   ReturnWrapper = true returns the wrapper bytes instead of parsing, for
//                   byte-level debugging against the B_*.parquet fixtures
//
// SPDX-License-Identifier: Apache-2.0
let
    Codec.Decompress = (compressed as binary, compression as number, optional uncompressedSize as nullable number, optional options as nullable record) as binary =>
    let
        opts = options ?? [],
        returnWrapper = Record.FieldOrDefault(opts, "ReturnWrapper", false) = true,
        lz4Framing = Record.FieldOrDefault(opts, "LZ4Framing", "Raw"),

        // ---- Compression.Type -> parquet CompressionCodec enum --------------
        codecId =
            if compression = Compression.None then 0
            else if compression = Compression.Snappy then 1
            else if compression = Compression.GZip then 2
            else if compression = Compression.Brotli then 4
            else if compression = Compression.LZ4 then (if lz4Framing = "Hadoop" then 5 else 7)
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
        usize =
            if uncompressedSize <> null then uncompressedSize
            else if compression = Compression.None then blobLen
            else if compression = Compression.Snappy then SnappyPreambleSize
            else if compression = Compression.GZip then GZipTrailerSize
            else if compression = Compression.LZ4 and lz4Framing = "Hadoop" then LZ4HadoopHeaderSize
            else error Error.Record("DataFormat.Error",
                "Brotli, Zstandard and raw LZ4 streams do not carry a reliable size header; pass uncompressedSize explicitly"),

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
