// Crc32.Compute - CRC-32 checksums in pure Power Query M.
//
// M's standard library has no hashing, but binary formats are full of CRC-32
// fields: gzip trailers, zip central directories, PNG chunks, Avro snappy
// blocks (plain CRC-32 of the uncompressed data), snappy framing-format
// chunks (masked CRC-32C). This function computes them with a buffered
// 256-entry lookup table, one table lookup and three bitwise ops per byte.
//
//     Crc32.Compute(data)                                // CRC-32 (zlib/gzip/zip/png)
//     Crc32.Compute(data, "CRC32C")                      // Castagnoli (snappy, iSCSI)
//     Crc32.Compute(data, "CRC32C", [SnappyMask = true]) // snappy framing-format mask
//
// Variants: CRC32 (aliases ISO-HDLC, zlib, gzip, zip, png), CRC32C (aliases
// Castagnoli, iSCSI, snappy), JAMCRC, BZIP2, MPEG2. Names are matched
// case-insensitively, ignoring "-", "/", "_" and spaces.
//
// Every intermediate stays below 2^32 by construction: the reflected engine
// only shifts right, and the forward engine masks after every left shift.
// Correctness never depends on the runtime's integer conversion behavior.
//
// SPDX-License-Identifier: Apache-2.0
let
    Crc32.Compute = (data as binary, optional variant as nullable text, optional options as nullable record) as number =>
    let
        opts = options ?? [],

        // ---- variant catalog ------------------------------------------------
        // reflected variants store the reflected polynomial (right-shift
        // engine); forward variants store the plain one (left-shift engine)
        Variants = [
            ISOHDLC = [Poly = 0xEDB88320, Init = 0xFFFFFFFF, Reflected = true, XorOut = 0xFFFFFFFF],
            CRC32C  = [Poly = 0x82F63B78, Init = 0xFFFFFFFF, Reflected = true, XorOut = 0xFFFFFFFF],
            JAMCRC  = [Poly = 0xEDB88320, Init = 0xFFFFFFFF, Reflected = true, XorOut = 0x00000000],
            BZIP2   = [Poly = 0x04C11DB7, Init = 0xFFFFFFFF, Reflected = false, XorOut = 0xFFFFFFFF],
            MPEG2   = [Poly = 0x04C11DB7, Init = 0xFFFFFFFF, Reflected = false, XorOut = 0x00000000]
        ],
        Aliases = [
            CRC32 = "ISOHDLC", ISOHDLC = "ISOHDLC", ZLIB = "ISOHDLC", GZIP = "ISOHDLC",
            ZIP = "ISOHDLC", PNG = "ISOHDLC",
            CRC32C = "CRC32C", CASTAGNOLI = "CRC32C", ISCSI = "CRC32C", SNAPPY = "CRC32C",
            JAMCRC = "JAMCRC", BZIP2 = "BZIP2", MPEG2 = "MPEG2"
        ],
        normalized = Text.Upper(Text.Remove(variant ?? "CRC32", {"-", "/", "_", " "})),
        key =
            if Record.HasFields(Aliases, normalized) then Record.Field(Aliases, normalized)
            else error Error.Record("DataFormat.Error",
                "Unknown CRC-32 variant '" & (variant ?? "") & "'. Known: CRC32 (ISO-HDLC, zlib, gzip, zip, png), CRC32C (Castagnoli, iSCSI, snappy), JAMCRC, BZIP2, MPEG2"),
        v = Record.Field(Variants, key),

        Mask32 = (n as number) as number => Number.BitwiseAnd(n, 0xFFFFFFFF),

        // ---- 256-entry lookup tables (only the needed one evaluates) --------
        ReflectedTable = List.Buffer(List.Transform({0..255}, (n) =>
            List.Accumulate({0..7}, n, (c, _) =>
                if Number.BitwiseAnd(c, 1) = 1
                then Number.BitwiseXor(Number.BitwiseShiftRight(c, 1), v[Poly])
                else Number.BitwiseShiftRight(c, 1)))),
        ForwardTable = List.Buffer(List.Transform({0..255}, (n) =>
            List.Accumulate({0..7}, Number.BitwiseShiftLeft(n, 24), (c, _) =>
                if Number.BitwiseAnd(c, 0x80000000) <> 0
                then Mask32(Number.BitwiseXor(Number.BitwiseShiftLeft(c, 1), v[Poly]))
                else Mask32(Number.BitwiseShiftLeft(c, 1))))),

        // ---- one pass over the bytes ----------------------------------------
        raw =
            if v[Reflected] then
                List.Accumulate(Binary.ToList(data), v[Init], (c, b) =>
                    Number.BitwiseXor(
                        Number.BitwiseShiftRight(c, 8),
                        ReflectedTable{Number.BitwiseAnd(Number.BitwiseXor(c, b), 0xFF)}))
            else
                List.Accumulate(Binary.ToList(data), v[Init], (c, b) =>
                    Number.BitwiseXor(
                        Mask32(Number.BitwiseShiftLeft(c, 8)),
                        ForwardTable{Number.BitwiseXor(Number.BitwiseShiftRight(c, 24), b)})),
        crc = Number.BitwiseXor(raw, v[XorOut]),

        // snappy framing format masks its CRC-32C so that CRCs of CRCs stay
        // well distributed: rotate right 15, add a constant, mod 2^32
        result =
            if Record.FieldOrDefault(opts, "SnappyMask", false) = true then
                Number.Mod(
                    Number.BitwiseOr(
                        Number.BitwiseShiftRight(crc, 15),
                        Mask32(Number.BitwiseShiftLeft(crc, 17)))
                    + 0xA282EAD8,
                    0x100000000)
            else crc
    in
        result
in
    Crc32.Compute
