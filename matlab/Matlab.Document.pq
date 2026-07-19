// SPDX-License-Identifier: Apache-2.0
//
// Matlab.Document.pq: read MATLAB MAT-files (.mat, v5/v6/v7) in pure Power Query M.
// No MATLAB licence, no Python interpreter, no COM automation, no custom connector required.
// Paste into a blank query (name it Matlab.Document), or wrap as a function in your PBIX / dataflow.
//
// Usage:
//   let
//       Matlab.Document = <this expression>,
//       doc = Matlab.Document(File.Contents("C:\path\to\results.mat")),  // nav table
//       m   = doc{[Name = "measurements"]}[Data]
//   in
//       m
//
// Options (optional second argument, all keys optional):
//   Encoding   TextEncoding or codepage number for char data stored in the
//              legacy 8-bit form (miINT8/miUINT8), default Windows-1252.
//              UTF-8/UTF-16/UTF-32 char data carries its own encoding.
//   Strict     logical, default false; when true, tolerated malformations
//              become errors (an unknown top-level element type, a compressed
//              element that does not hold a matrix, a function handle).
//
// Supported: MAT-file level 5 files as written by MATLAB v5 through v7.2
//            (save -v6 / -v7) and by scipy.io.savemat; both byte orders
//            ("IM" little-endian and "MI" big-endian); compressed variables
//            (v7, zlib) and uncompressed (v6); numeric storage compression
//            (a double array stored as int8 etc.); all numeric classes
//            int8-uint64/single/double, logical, char, complex, cell arrays,
//            structs and struct arrays, objects (read as structs), sparse
//            matrices, N-dimensional arrays.
// Not supported: v7.3 files (HDF5 containers, clear error; re-save with
//            "save -v7"); v4 files (clear error); function handles and
//            opaque/Java objects load as null (error under Strict);
//            int64/uint64 values beyond 2^53 lose precision.
// Output:    a navigation table with one row per variable (Name, Class,
//            Dimensions, Data) with Matlab.HeaderText, Matlab.ByteOrder,
//            Matlab.SubsystemDataOffset and Matlab.VariableCount in the
//            table metadata. Each variable converts by shape:
//              1x1             the scalar itself (complex: a [Re, Im] record)
//              1xN / Nx1       a list (char row vector: a text)
//              MxN             a table with columns C1..CN (char matrix:
//                              a list of M texts)
//              more than 2 dims  a long table D1..Dk + Value (column-major)
//              1x1 struct      a record of fields
//              struct array    a table, one row per element, a column per
//                              field (with D1..Dk index columns when not a
//                              vector)
//              cell array      shaped like a numeric array, elements converted
//                              recursively
//              sparse          a table {Row, Column, Value}, 1-based, in
//                              column-major (CSC) order
//              any empty array null (empty char: "")

(source as binary, optional options as nullable record) as table =>
let
    bin   = Binary.Buffer(source),
    total = Binary.Length(bin),

    opts        = if options = null then [] else options,
    OptStrict   = Record.FieldOrDefault(opts, "Strict", false) = true,
    OptEncoding = Record.FieldOrDefault(opts, "Encoding", null),
    Enc         = if OptEncoding <> null then OptEncoding else 1252,

    //==================== low-level byte access ====================
    Slice = (b as binary, offset as number, count as number) as binary =>
        if count <= 0 then #binary({})
        else if offset = 0 then BinaryFormat.Binary(count)(b)
        else BinaryFormat.Record([
                Skip = BinaryFormat.Binary(offset),
                Data = BinaryFormat.Binary(count)
             ])(b)[Data],

    NumList = (n as number) as list => if n <= 0 then {} else {0 .. n - 1},

    Ascii = (b as binary, off as number, count as number) as text =>
        if count <= 0 then ""
        else Text.FromBinary(Slice(b, off, count), TextEncoding.Ascii),

    // a \0-terminated string inside a fixed-width field
    CStrAscii = (b as binary, off as number, width as number) as text =>
        let
            bytes = Binary.ToList(Slice(b, off, width)),
            z     = List.PositionOf(bytes, 0),
            n     = if z = -1 then width else z
        in
            Text.FromBinary(#binary(List.FirstN(bytes, n)), TextEncoding.Ascii),

    Pad8 = (n as number) as number =>
        if Number.Mod(n, 8) = 0 then n else n + 8 - Number.Mod(n, 8),

    //==================== header ====================
    // 128 bytes: 116 bytes of descriptive text, an 8-byte subsystem data
    // offset, a 2-byte version, and the endian indicator "IM" (LE) / "MI" (BE)
    Hdf5Sig = #binary({0x89, 0x48, 0x44, 0x46, 0x0D, 0x0A, 0x1A, 0x0A}),
    CheckNotHdf5 =
        if total >= 8 and Slice(bin, 0, 8) = Hdf5Sig
        then error Error.Record("DataFormat.Error",
                "This is a MATLAB v7.3 MAT-file, which is an HDF5 container. " &
                "Re-save it in MATLAB with save('file.mat','-v7') to get a " &
                "supported file.", null)
        else true,
    CheckLength =
        if CheckNotHdf5 and total < 128
        then error Error.Record("DataFormat.Error",
                "Not a MAT-file (shorter than the 128-byte header).", null)
        else true,

    IsLE =
        if CheckLength then
            let e = Ascii(bin, 126, 2)
            in
                if e = "IM" then true
                else if e = "MI" then false
                // a v4 file starts with a small little-endian integer
                else if BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger32,
                        ByteOrder.LittleEndian)(bin) < 5000
                then error Error.Record("DataFormat.Error",
                        "This looks like a MATLAB v4 MAT-file. Re-save it in " &
                        "MATLAB with save('file.mat','-v7') to get a " &
                        "supported file.", null)
                else error Error.Record("DataFormat.Error",
                        "Not a MAT-file (endian indicator not found).", null)
        else false,

    BO = if IsLE then ByteOrder.LittleEndian else ByteOrder.BigEndian,

    U16Fmt = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger16, BO),
    U32Fmt = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger32, BO),
    U64Fmt = BinaryFormat.ByteOrder(BinaryFormat.UnsignedInteger64, BO),
    I16Fmt = BinaryFormat.ByteOrder(BinaryFormat.SignedInteger16, BO),
    I32Fmt = BinaryFormat.ByteOrder(BinaryFormat.SignedInteger32, BO),
    I64Fmt = BinaryFormat.ByteOrder(BinaryFormat.SignedInteger64, BO),
    F32Fmt = BinaryFormat.ByteOrder(BinaryFormat.Single, BO),
    F64Fmt = BinaryFormat.ByteOrder(BinaryFormat.Double, BO),

    U32Of = (b as binary, off as number) as number => U32Fmt(Slice(b, off, 4)),

    // evaluating U16Fmt forces BO and with it every header check above
    Version = U16Fmt(Slice(bin, 124, 2)),
    CheckVersion =
        if Version = 0x0200
        then error Error.Record("DataFormat.Error",
                "This is a MATLAB v7.3 MAT-file, which is an HDF5 container. " &
                "Re-save it in MATLAB with save('file.mat','-v7') to get a " &
                "supported file.", null)
        else if Version <> 0x0100 and OptStrict
        then error Error.Record("DataFormat.Error",
                "Unrecognized MAT-file version.", [Version = Version])
        else true,

    HeaderText = Text.TrimEnd(CStrAscii(bin, 0, 116)),
    SubsysBytes = Slice(bin, 116, 8),
    SubsysOff =
        if SubsysBytes = #binary({0, 0, 0, 0, 0, 0, 0, 0})
           or SubsysBytes = #binary({32, 32, 32, 32, 32, 32, 32, 32})
        then null
        else U64Fmt(SubsysBytes),

    //==================== data elements ====================
    // A data element is an 8-byte tag (uint32 type, uint32 byte count) plus
    // payload padded to 8 bytes, unless the high 16 bits of the first word
    // are nonzero, which marks the small format: 2-byte type, 2-byte count,
    // up to 4 bytes of payload, 8 bytes in all.
    ReadElement = (b as binary, off as number) as record =>
        let
            word  = U32Of(b, off),
            small = Number.BitwiseShiftRight(word, 16)
        in
            if small <> 0 then
                [Type    = Number.BitwiseAnd(word, 0xFFFF),
                 Payload = Slice(b, off + 4, small),
                 Next    = off + 8]
            else
                let size = U32Of(b, off + 4)
                in
                    [Type    = word,
                     Payload = Slice(b, off + 8, size),
                     Next    = off + 8 + Pad8(size)],

    // numeric payload -> list of numbers, per the element's storage type
    // (miINT8=1 .. miUINT64=13); the array class decides meaning, not this
    NumbersOf = (payload as binary, mdtype as number) as list =>
        if mdtype = 1 then
            List.Transform(Binary.ToList(payload),
                (x) => if x > 127 then x - 256 else x)
        else if mdtype = 2 then Binary.ToList(payload)
        else if mdtype = 3 then BinaryFormat.List(I16Fmt)(payload)
        else if mdtype = 4 then BinaryFormat.List(U16Fmt)(payload)
        else if mdtype = 5 then BinaryFormat.List(I32Fmt)(payload)
        else if mdtype = 6 then BinaryFormat.List(U32Fmt)(payload)
        else if mdtype = 7 then BinaryFormat.List(F32Fmt)(payload)
        else if mdtype = 9 then BinaryFormat.List(F64Fmt)(payload)
        else if mdtype = 12 then BinaryFormat.List(I64Fmt)(payload)
        else if mdtype = 13 then BinaryFormat.List(U64Fmt)(payload)
        else error Error.Record("DataFormat.Error",
                "Unexpected data type in a numeric element.",
                [Type = mdtype]),

    // char payload -> flat text, per the element's storage type; miUINT16
    // (what MATLAB writes) and miUTF16 are UTF-16 in the file's byte order,
    // miUTF8 carries its own encoding, miINT8/miUINT8 use the Encoding option
    CharsOf = (payload as binary, mdtype as number) as text =>
        if mdtype = 16 then Text.FromBinary(payload, TextEncoding.Utf8)
        else if mdtype = 4 or mdtype = 17 then
            (if IsLE then Text.FromBinary(payload, TextEncoding.Utf16)
             else Text.Combine(List.Transform(
                    BinaryFormat.List(U16Fmt)(payload), Character.FromNumber)))
        else if mdtype = 18 then
            Text.Combine(List.Transform(
                BinaryFormat.List(U32Fmt)(payload), Character.FromNumber))
        else if mdtype = 1 or mdtype = 2 then Text.FromBinary(payload, Enc)
        else error Error.Record("DataFormat.Error",
                "Unexpected data type in a char element.", [Type = mdtype]),

    //==================== shaping: flat column-major values ====================
    // prefix products {1, d1, d1*d2, ...}; element t of a column-major array
    // sits at index (t div prods{i}) mod dims{i} along dimension i
    IndexColumns = (dims as list) as list =>
        List.Transform(NumList(List.Count(dims)),
            (i) => "D" & Number.ToText(i + 1)),
    IndexOf = (dims as list, prods as list, t as number) as list =>
        List.Transform(NumList(List.Count(dims)),
            (i) => Number.Mod(Number.IntegerDivide(t, prods{i}), dims{i}) + 1),
    PrefixProducts = (dims as list) as list =>
        List.Generate(
            () => [I = 0, P = 1],
            (s) => s[I] < List.Count(dims),
            (s) => [I = s[I] + 1, P = s[P] * dims{s[I]}],
            (s) => s[P]),

    TypeAll = (t as table, cols as list, colType as nullable type) as table =>
        if colType = null then t
        else Table.TransformColumnTypes(t,
                List.Transform(cols, (c) => {c, colType})),

    LongTable = (vals as list, dims as list, colType as nullable type) as table =>
        let
            prods = List.Buffer(PrefixProducts(dims)),
            dcols = IndexColumns(dims),
            rows  = List.Transform(NumList(List.Count(vals)),
                        (t) => IndexOf(dims, prods, t) & {vals{t}}),
            base  = Table.TransformColumnTypes(
                        #table(dcols & {"Value"}, rows),
                        List.Transform(dcols, (c) => {c, Int64.Type}))
        in
            TypeAll(base, {"Value"}, colType),

    ShapeValues = (vals as list, dims as list, colType as nullable type) as any =>
        if List.Contains(dims, 0) then null
        else if List.Count(dims) > 2 then LongTable(vals, dims, colType)
        else
            let m = dims{0}, n = dims{1}
            in
                if m = 1 and n = 1 then vals{0}
                else if m = 1 or n = 1 then vals
                else
                    let
                        cols = List.Transform(NumList(n),
                                   (j) => "C" & Number.ToText(j + 1)),
                        rows = List.Transform(NumList(m), (i) =>
                                   List.Transform(NumList(n),
                                       (j) => vals{i + j * m}))
                    in
                        TypeAll(#table(cols, rows), cols, colType),

    ShapeChar = (flat as text, dims as list) as any =>
        if List.Contains(dims, 0) then ""
        else if List.Count(dims) > 2 then
            LongTable(Text.ToList(flat), dims, type text)
        else
            let m = dims{0}, n = dims{1}
            in
                if m = 1 then flat
                else
                    let chars = List.Buffer(Text.ToList(flat))
                    in
                        List.Transform(NumList(m), (i) =>
                            Text.Combine(List.Transform(NumList(n),
                                (j) => chars{i + j * m}))),

    ShapeStruct = (elems as list, fields as list, dims as list) as any =>
        if List.Contains(dims, 0) then null
        else if List.Count(elems) = 1 and List.Count(dims) = 2
        then Record.FromList(elems{0}, fields)
        else if List.Count(dims) = 2 and (dims{0} = 1 or dims{1} = 1)
        then #table(fields, elems)
        else
            let
                prods = List.Buffer(PrefixProducts(dims)),
                dcols = IndexColumns(dims),
                rows  = List.Transform(NumList(List.Count(elems)),
                            (t) => IndexOf(dims, prods, t) & elems{t})
            in
                Table.TransformColumnTypes(
                    #table(dcols & fields, rows),
                    List.Transform(dcols, (c) => {c, Int64.Type})),

    //==================== one miMATRIX body ====================
    // subelements in order: array flags (miUINT32 x2), dimensions (miINT32),
    // name (miINT8), then per class; returns null for a zero-byte matrix
    ReadMatrix = (b as binary, off as number, end as number) as nullable record =>
        if off >= end then null
        else
        let
            eFlags = ReadElement(b, off),
            fw = if eFlags[Type] = 6 and Binary.Length(eFlags[Payload]) >= 8
                 then NumbersOf(eFlags[Payload], 6)
                 else error Error.Record("DataFormat.Error",
                        "Malformed matrix element (array flags not found).",
                        [Offset = off]),
            word0     = fw{0},
            nzmax     = fw{1},
            Class     = Number.BitwiseAnd(word0, 0xFF),
            flagBits  = Number.BitwiseAnd(Number.BitwiseShiftRight(word0, 8), 0xFF),
            IsComplex = Number.BitwiseAnd(flagBits, 8) <> 0,
            IsGlobal  = Number.BitwiseAnd(flagBits, 4) <> 0,
            IsLogical = Number.BitwiseAnd(flagBits, 2) <> 0,

            eDims = ReadElement(b, eFlags[Next]),
            dims  = List.Buffer(NumbersOf(eDims[Payload], eDims[Type])),
            count = List.Product(dims),

            eName = ReadElement(b, eDims[Next]),
            name  = Text.FromBinary(eName[Payload], TextEncoding.Ascii),
            p0    = eName[Next],

            parsed =
                // function handles and opaque objects have no data representation
                if Class = 16 or Class = 17 then
                    let cn = if Class = 16 then "function_handle" else "opaque"
                    in
                        [ClassName = cn,
                         Value = if OptStrict
                                 then error Error.Record("DataFormat.Error",
                                        "Variable '" & name & "' is a " & cn &
                                        "; it has no data representation.", null)
                                 else null]
                // char
                else if Class = 4 then
                    let eData = ReadElement(b, p0)
                    in
                        [ClassName = "char",
                         Value = ShapeChar(CharsOf(eData[Payload], eData[Type]),
                                           dims)]
                // sparse: ir (row indices), jc (column pointers), pr, pi
                else if Class = 5 then
                    let
                        eIr = ReadElement(b, p0),
                        ir  = List.Buffer(NumbersOf(eIr[Payload], eIr[Type])),
                        eJc = ReadElement(b, eIr[Next]),
                        jc  = List.Buffer(NumbersOf(eJc[Payload], eJc[Type])),
                        ePr = ReadElement(b, eJc[Next]),
                        pr  = List.Buffer(NumbersOf(ePr[Payload], ePr[Type])),
                        ePi = if IsComplex then ReadElement(b, ePr[Next]) else null,
                        pi  = if IsComplex
                              then List.Buffer(NumbersOf(ePi[Payload], ePi[Type]))
                              else null,
                        ncols = if List.Count(dims) > 1 then dims{1} else 0,
                        rows  = List.Combine(List.Transform(NumList(ncols), (j) =>
                                    let k0 = jc{j}, k1 = jc{j + 1}
                                    in
                                        List.Transform(NumList(k1 - k0), (t) =>
                                            let k = k0 + t
                                            in
                                                {ir{k} + 1, j + 1,
                                                 if IsLogical then pr{k} <> 0
                                                 else if IsComplex
                                                 then [Re = pr{k}, Im = pi{k}]
                                                 else pr{k}}))),
                        base = Table.TransformColumnTypes(
                                   #table({"Row", "Column", "Value"}, rows),
                                   {{"Row", Int64.Type}, {"Column", Int64.Type}}),
                        vType = if IsComplex then null
                                else if IsLogical then type logical
                                else type number
                    in
                        [ClassName = "sparse", Value = TypeAll(base, {"Value"}, vType)]
                // cell array: count nested matrix elements, column-major
                else if Class = 1 then
                    let
                        st = List.Accumulate(NumList(count), [P = p0, Items = {}],
                                (s, i) =>
                                    let
                                        t    = U32Of(b, s[P]),
                                        size = U32Of(b, s[P] + 4),
                                        item = if t = 14
                                               then @ReadMatrix(b, s[P] + 8,
                                                                s[P] + 8 + size)
                                               else error Error.Record(
                                                      "DataFormat.Error",
                                                      "Malformed cell array " &
                                                      "(expected a matrix element).",
                                                      [Offset = s[P]])
                                    in
                                        [P = s[P] + 8 + Pad8(size),
                                         Items = s[Items] &
                                             {if item = null then null
                                              else item[Value]}])
                    in
                        [ClassName = "cell", Value = ShapeValues(st[Items], dims, null)]
                // struct / object: (class name,) field name length, field
                // names, then count*nfields matrices, fields fastest
                else if Class = 2 or Class = 3 then
                    let
                        cnp = if Class = 3
                              then let ec = ReadElement(b, p0)
                                   in  [CN = "object:" & Text.FromBinary(
                                            ec[Payload], TextEncoding.Ascii),
                                        P = ec[Next]]
                              else [CN = "struct", P = p0],
                        eFnl   = ReadElement(b, cnp[P]),
                        fnlen  = NumbersOf(eFnl[Payload], eFnl[Type]){0},
                        eFn    = ReadElement(b, eFnl[Next]),
                        nf     = if fnlen > 0
                                 then Number.IntegerDivide(
                                          Binary.Length(eFn[Payload]), fnlen)
                                 else 0,
                        fields = List.Buffer(List.Transform(NumList(nf),
                                     (i) => CStrAscii(eFn[Payload],
                                                      i * fnlen, fnlen))),
                        st = List.Accumulate(NumList(count * nf),
                                [P = eFn[Next], Items = {}], (s, i) =>
                                    let
                                        t    = U32Of(b, s[P]),
                                        size = U32Of(b, s[P] + 4),
                                        item = if t = 14
                                               then @ReadMatrix(b, s[P] + 8,
                                                                s[P] + 8 + size)
                                               else error Error.Record(
                                                      "DataFormat.Error",
                                                      "Malformed struct " &
                                                      "(expected a matrix element).",
                                                      [Offset = s[P]])
                                    in
                                        [P = s[P] + 8 + Pad8(size),
                                         Items = s[Items] &
                                             {if item = null then null
                                              else item[Value]}]),
                        elems = if nf = 0
                                then List.Transform(NumList(count), (i) => {})
                                else List.Split(st[Items], nf)
                    in
                        [ClassName = cnp[CN],
                         Value = ShapeStruct(elems, fields, dims)]
                // numeric: real part (storage type may be narrower than the
                // class), imaginary part when the complex flag is set
                else if Class >= 6 and Class <= 15 then
                    let
                        eRe = ReadElement(b, p0),
                        re  = NumbersOf(eRe[Payload], eRe[Type]),
                        eIm = if IsComplex then ReadElement(b, eRe[Next]) else null,
                        im  = if IsComplex
                              then List.Buffer(NumbersOf(eIm[Payload], eIm[Type]))
                              else null,
                        vals = if IsLogical
                               then List.Transform(re, (x) => x <> 0)
                               else if IsComplex
                               then List.Transform(NumList(List.Count(re)),
                                        (i) => [Re = re{i}, Im = im{i}])
                               else re,
                        cType = if IsComplex then null
                                else if IsLogical then type logical
                                else if Class = 6 or Class = 7 then type number
                                else Int64.Type,
                        names = {"", "cell", "struct", "object", "char", "sparse",
                                 "double", "single", "int8", "uint8", "int16",
                                 "uint16", "int32", "uint32", "int64", "uint64"}
                    in
                        [ClassName = names{Class},
                         Value = ShapeValues(List.Buffer(vals), dims, cType)]
                else error Error.Record("DataFormat.Error",
                        "Unknown array class.", [Class = Class])
        in
            [Name      = name,
             ClassName = parsed[ClassName],
             Dims      = dims,
             IsComplex = IsComplex,
             IsGlobal  = IsGlobal,
             IsLogical = IsLogical,
             Value     = parsed[Value]],

    //==================== top-level walk ====================
    // Elements from offset 128: miMATRIX (14) is a variable; miCOMPRESSED
    // (15) is a zlib stream (2-byte header + deflate + Adler-32) holding one
    // complete element: strip the 2 bytes, inflate, ignore the checksum.
    // Compressed elements are not 8-padded; everything else is.
    TopStep = (p as number) as nullable record =>
        if p + 8 > total then null
        else
        let
            word = U32Of(bin, p),
            size = U32Of(bin, p + 4)
        in
            if word = 15 then
                let
                    inner = Binary.Buffer(Binary.Decompress(
                                Slice(bin, p + 10, size - 2),
                                Compression.Deflate)),
                    itype = U32Of(inner, 0),
                    isize = U32Of(inner, 4),
                    v     = if itype = 14 then ReadMatrix(inner, 8, 8 + isize)
                            else if OptStrict
                            then error Error.Record("DataFormat.Error",
                                    "A compressed element does not hold a matrix.",
                                    [Type = itype, Offset = p])
                            else null
                in
                    [Var = v, Next = p + 8 + size]
            else if word = 14 then
                [Var = ReadMatrix(bin, p + 8, p + 8 + size),
                 Next = p + 8 + Pad8(size)]
            else if OptStrict then
                error Error.Record("DataFormat.Error",
                        "Unexpected top-level element type.",
                        [Type = word, Offset = p])
            else
                [Var = null, Next = p + 8 + Pad8(size)],

    Start = if CheckVersion then 128 else 0,
    Steps = List.Generate(
        () => TopStep(Start),
        (s) => s <> null,
        (s) => TopStep(s[Next]),
        (s) => s[Var]),
    // a nameless top-level matrix is MATLAB's subsystem data blob
    // (function-handle workspaces), not a variable
    Vars = List.Buffer(List.Select(Steps,
        (v) => v <> null and v[Name] <> "")),

    //==================== navigation table ====================
    DimsText = (dims as list) as text =>
        Text.Combine(List.Transform(dims, Number.ToText), "x"),
    ClassText = (v as record) as text =>
        if v[IsLogical] then
            (if v[ClassName] = "sparse" then "sparse logical" else "logical")
        else if v[IsComplex] then v[ClassName] & " complex"
        else v[ClassName],
    KindOf = (x as any) as text =>
        if x is table then "Table"
        else if x is record then "Record"
        else "DefinedName",

    NavType =
        Type.AddTableKey(
            type table [Name = text, Class = text, Dimensions = text,
                        Data = any, ItemKind = text, ItemName = text,
                        IsLeaf = logical],
            {"Name"}, true)
        meta [
            NavigationTable.NameColumn = "Name",
            NavigationTable.DataColumn = "Data",
            NavigationTable.ItemKindColumn = "ItemKind",
            Preview.DelayColumn = "ItemName",
            NavigationTable.IsLeafColumn = "IsLeaf"
        ],

    Nav = Value.ReplaceType(
              #table({"Name", "Class", "Dimensions", "Data", "ItemKind",
                      "ItemName", "IsLeaf"},
                     List.Transform(Vars, (v) =>
                         let k = KindOf(v[Value])
                         in
                             {v[Name], ClassText(v), DimsText(v[Dims]),
                              v[Value], k, k, true})),
              NavType)
          meta [
              Matlab.HeaderText           = HeaderText,
              Matlab.ByteOrder            = if IsLE then "IM" else "MI",
              Matlab.SubsystemDataOffset  = SubsysOff,
              Matlab.VariableCount        = List.Count(Vars)
          ]
in
    Nav
