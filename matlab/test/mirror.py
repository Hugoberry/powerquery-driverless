# SPDX-License-Identifier: Apache-2.0
#
# Pure-Python mirror of the parse logic destined for Matlab.Document.pq.
# Byte-level only, no numpy, no scipy. Every algorithmic decision in the
# M reader is prototyped here first, then this mirror is cross-validated
# cell-by-cell against scipy.io.loadmat (the de facto open reader of
# record) by check_mirror.py.
#
# Structure intentionally parallels the M reader:
#   parse(data) -> {header_text, version, endian, subsys_offset, variables}
# where variables is an ordered list of
#   {name, class, dims, complex, global, logical, value}
# and value follows the reader's conversion contract (documented in
# ../README.md):
#
#   numeric / logical / char / cell, by shape:
#     any zero dimension        -> None (char -> "")
#     1x1                       -> scalar (complex -> {Re, Im} record)
#     1xN or Nx1 (2-D vector)   -> list (char row vector -> text)
#     MxN                       -> table, columns C1..CN (char -> list of
#                                  M texts, one per row)
#     more than 2 dims          -> long table D1..Dk + Value, column-major
#   struct / object:
#     1x1                       -> record of fields
#     vector                    -> table, one row per element, one column
#                                  per field
#     otherwise                 -> same table with D1..Dk index columns
#   sparse                      -> table {Row, Column, Value}, 1-based,
#                                  column-major (CSC) order
#   function handle / opaque    -> None (error under Strict)
#
# Tables are represented as {"__table__": {"columns": [...], "rows": [...]}}
# and records as {"__record__": {...}} so check_mirror.py can compare
# structurally.

import struct
import zlib

# MAT-file data types (mi*)
miINT8, miUINT8, miINT16, miUINT16 = 1, 2, 3, 4
miINT32, miUINT32, miSINGLE, miDOUBLE = 5, 6, 7, 9
miINT64, miUINT64, miMATRIX, miCOMPRESSED = 12, 13, 14, 15
miUTF8, miUTF16, miUTF32 = 16, 17, 18

# array classes (mx*)
mxCELL, mxSTRUCT, mxOBJECT, mxCHAR, mxSPARSE = 1, 2, 3, 4, 5
mxDOUBLE, mxSINGLE = 6, 7
mxINT8, mxUINT8, mxINT16, mxUINT16 = 8, 9, 10, 11
mxINT32, mxUINT32, mxINT64, mxUINT64 = 12, 13, 14, 15
mxFUNCTION, mxOPAQUE = 16, 17

CLASS_NAMES = {
    mxCELL: "cell", mxSTRUCT: "struct", mxOBJECT: "object", mxCHAR: "char",
    mxSPARSE: "sparse", mxDOUBLE: "double", mxSINGLE: "single",
    mxINT8: "int8", mxUINT8: "uint8", mxINT16: "int16", mxUINT16: "uint16",
    mxINT32: "int32", mxUINT32: "uint32", mxINT64: "int64",
    mxUINT64: "uint64", mxFUNCTION: "function_handle", mxOPAQUE: "opaque",
}

INT_CLASSES = {mxINT8, mxUINT8, mxINT16, mxUINT16, mxINT32, mxUINT32,
               mxINT64, mxUINT64}

# numeric storage types: struct letter and width (endian prefix added later)
NUM_FMT = {
    miINT8: ("b", 1), miUINT8: ("B", 1), miINT16: ("h", 2),
    miUINT16: ("H", 2), miINT32: ("i", 4), miUINT32: ("I", 4),
    miSINGLE: ("f", 4), miDOUBLE: ("d", 8), miINT64: ("q", 8),
    miUINT64: ("Q", 8),
}


class MatError(Exception):
    pass


def table(columns, rows):
    return {"__table__": {"columns": columns, "rows": rows}}


def record(fields):
    return {"__record__": fields}


def parse(data, strict=False, encoding="cp1252"):
    if len(data) < 128:
        raise MatError("Not a MAT-file (shorter than the 128-byte header).")
    if data[:8] == b"\x89HDF\r\n\x1a\n":
        raise MatError("This is a MATLAB v7.3 (HDF5) file; not supported.")

    endian_bytes = data[126:128]
    if endian_bytes == b"IM":
        e = "<"
    elif endian_bytes == b"MI":
        e = ">"
    else:
        # a v4 file starts with a small little-endian integer, not text
        first = struct.unpack("<I", data[:4])[0]
        if first < 5000:
            raise MatError("This looks like a MATLAB v4 MAT-file; "
                           "re-save it as v5/v6/v7.")
        raise MatError("Not a MAT-file (endian indicator not found).")

    version = struct.unpack(e + "H", data[124:126])[0]
    if version == 0x0200:
        raise MatError("This is a MATLAB v7.3 (HDF5) file; not supported.")
    if version != 0x0100 and strict:
        raise MatError("Unrecognized MAT-file version 0x%04x." % version)

    header_text = data[:116].split(b"\x00")[0].decode("ascii",
                                                      "replace").rstrip()
    subsys = struct.unpack(e + "Q", data[116:124])[0]
    subsys_off = subsys if subsys not in (0, 0x2020202020202020) else None

    st = _State(e, strict, encoding)

    variables = []
    p = 128
    total = len(data)
    while p + 8 <= total:
        mdtype, nbytes = struct.unpack_from(e + "II", data, p)
        if mdtype == miCOMPRESSED:
            # a zlib stream (2-byte header + deflate + Adler-32) holding one
            # complete element; compressed elements are not 8-padded
            payload = zlib.decompress(data[p + 8:p + 8 + nbytes])
            inner_type, inner_len = struct.unpack_from(e + "II", payload, 0)
            if inner_type == miMATRIX:
                v = st.read_matrix(payload, 8, 8 + inner_len)
                # a nameless top-level matrix is MATLAB's subsystem data
                # blob (function-handle workspaces), not a variable
                if v is not None and v["name"] != "":
                    variables.append(v)
            elif strict:
                raise MatError("Compressed element does not hold a matrix "
                               "(type %d)." % inner_type)
            p = p + 8 + nbytes
        elif mdtype == miMATRIX:
            v = st.read_matrix(data, p + 8, p + 8 + nbytes)
            if v is not None and v["name"] != "":
                variables.append(v)
            p = p + 8 + _pad8(nbytes)
        else:
            if strict:
                raise MatError("Unexpected top-level element type %d."
                               % mdtype)
            p = p + 8 + _pad8(nbytes)

    return {
        "header_text": header_text,
        "version": version,
        "endian": "IM" if e == "<" else "MI",
        "subsys_offset": subsys_off,
        "variables": variables,
    }


def _pad8(n):
    return n if n % 8 == 0 else n + 8 - n % 8


class _State:
    def __init__(self, e, strict, encoding):
        self.e = e
        self.strict = strict
        self.encoding = encoding

    # -- one subelement: returns (mdtype, payload, next_position) -------------
    def read_element(self, buf, p):
        word = struct.unpack_from(self.e + "I", buf, p)[0]
        if word >> 16 != 0:
            # small data element: 2-byte type, 2-byte length, <=4 bytes data
            mdtype = word & 0xFFFF
            nbytes = word >> 16
            return mdtype, buf[p + 4:p + 4 + nbytes], p + 8
        mdtype, nbytes = struct.unpack_from(self.e + "II", buf, p)
        return mdtype, buf[p + 8:p + 8 + nbytes], p + 8 + _pad8(nbytes)

    def numbers(self, mdtype, payload):
        if mdtype not in NUM_FMT:
            raise MatError("Unexpected data type %d in a numeric element."
                           % mdtype)
        letter, width = NUM_FMT[mdtype]
        n = len(payload) // width
        return list(struct.unpack(self.e + str(n) + letter, payload[:n * width]))

    def chars(self, mdtype, payload):
        """Decode a char-data element to a list of MATLAB chars."""
        if mdtype == miUTF8:
            return list(payload.decode("utf-8"))
        if mdtype in (miUINT16, miUTF16):
            enc = "utf-16-le" if self.e == "<" else "utf-16-be"
            return list(payload.decode(enc))
        if mdtype == miUTF32:
            enc = "utf-32-le" if self.e == "<" else "utf-32-be"
            return list(payload.decode(enc))
        if mdtype in (miINT8, miUINT8):
            return list(payload.decode(self.encoding))
        raise MatError("Unexpected data type %d in a char element." % mdtype)

    # -- one miMATRIX body: returns a variable dict or None -------------------
    def read_matrix(self, buf, p, end):
        if p >= end:
            return None                      # zero-byte matrix: no content
        mdtype, flags_payload, p = self.read_element(buf, p)
        if mdtype != miUINT32 or len(flags_payload) < 8:
            raise MatError("Malformed matrix (array flags not found).")
        word0, word1 = struct.unpack(self.e + "II", flags_payload[:8])
        klass = word0 & 0xFF
        flags = (word0 >> 8) & 0xFF
        is_complex = flags & 0x08 != 0
        is_global = flags & 0x04 != 0
        is_logical = flags & 0x02 != 0
        nzmax = word1

        mdtype, dims_payload, p = self.read_element(buf, p)
        dims = self.numbers(mdtype, dims_payload)
        count = 1
        for d in dims:
            count *= d

        mdtype, name_payload, p = self.read_element(buf, p)
        name = name_payload.decode("ascii", "replace")

        if klass in (mxFUNCTION, mxOPAQUE):
            if self.strict:
                raise MatError("Variable '%s' is a %s; not representable."
                               % (name, CLASS_NAMES[klass]))
            value = None
            class_name = CLASS_NAMES[klass]
        elif klass == mxCHAR:
            mdtype, payload, p = self.read_element(buf, p)
            value = self.shape_char(self.chars(mdtype, payload), dims)
            class_name = "char"
        elif klass == mxSPARSE:
            value = self.read_sparse(buf, p, dims, nzmax, is_complex,
                                     is_logical)
            class_name = "sparse"
        elif klass == mxCELL:
            cells = []
            for _ in range(count):
                mdtype, nbytes = struct.unpack_from(self.e + "II", buf, p)
                if mdtype != miMATRIX:
                    raise MatError("Malformed cell array (expected a matrix "
                                   "element).")
                item = self.read_matrix(buf, p + 8, p + 8 + nbytes)
                cells.append(None if item is None else item["value"])
                p = p + 8 + _pad8(nbytes)
            value = self.shape_values(cells, dims)
            class_name = "cell"
        elif klass in (mxSTRUCT, mxOBJECT):
            if klass == mxOBJECT:
                mdtype, cn_payload, p = self.read_element(buf, p)
                class_name = "object:" + cn_payload.decode("ascii", "replace")
            else:
                class_name = "struct"
            mdtype, fnl_payload, p = self.read_element(buf, p)
            fnlen = self.numbers(mdtype, fnl_payload)[0]
            mdtype, fn_payload, p = self.read_element(buf, p)
            nfields = len(fn_payload) // fnlen if fnlen > 0 else 0
            fields = [fn_payload[i * fnlen:(i + 1) * fnlen]
                      .split(b"\x00")[0].decode("ascii", "replace")
                      for i in range(nfields)]
            elems = []
            for _ in range(count):
                fieldvals = {}
                for f in fields:
                    mdtype, nbytes = struct.unpack_from(self.e + "II", buf, p)
                    if mdtype != miMATRIX:
                        raise MatError("Malformed struct (expected a matrix "
                                       "element).")
                    item = self.read_matrix(buf, p + 8, p + 8 + nbytes)
                    fieldvals[f] = None if item is None else item["value"]
                    p = p + 8 + _pad8(nbytes)
                elems.append(fieldvals)
            value = self.shape_struct(elems, fields, dims)
        else:
            if klass not in CLASS_NAMES or klass == mxCELL:
                raise MatError("Unknown array class %d." % klass)
            class_name = CLASS_NAMES[klass]
            mdtype, payload, p = self.read_element(buf, p)
            re = self.numbers(mdtype, payload)
            im = None
            if is_complex:
                mdtype, payload, p = self.read_element(buf, p)
                im = self.numbers(mdtype, payload)
            vals = self.combine(re, im, klass, is_logical)
            value = self.shape_values(vals, dims)

        return {
            "name": name,
            "class": class_name,
            "dims": dims,
            "complex": is_complex,
            "global": is_global,
            "logical": is_logical,
            "value": value,
        }

    def combine(self, re, im, klass, is_logical):
        if is_logical:
            return [x != 0 for x in re]
        if im is not None:
            return [record({"Re": self.num(r, klass), "Im": self.num(i, klass)})
                    for r, i in zip(re, im)]
        return [self.num(x, klass) for x in re]

    def num(self, x, klass):
        # the storage type may be narrower than the class ("numeric storage
        # compression"): the class decides integer-ness, not the storage
        return int(x) if klass in INT_CLASSES else float(x)

    # -- shaping: flat column-major values -> contract shapes -----------------
    def shape_values(self, vals, dims):
        if any(d == 0 for d in dims):
            return None
        if len(dims) > 2:
            cols = ["D%d" % (i + 1) for i in range(len(dims))] + ["Value"]
            rows = []
            idx = [1] * len(dims)
            for v in vals:
                rows.append(list(idx) + [v])
                for i in range(len(dims)):
                    idx[i] += 1
                    if idx[i] <= dims[i]:
                        break
                    idx[i] = 1
            return table(cols, rows)
        m, n = dims
        if m == 1 and n == 1:
            return vals[0]
        if m == 1 or n == 1:
            return vals
        cols = ["C%d" % (j + 1) for j in range(n)]
        rows = [[vals[i + j * m] for j in range(n)] for i in range(m)]
        return table(cols, rows)

    def shape_char(self, chars, dims):
        if any(d == 0 for d in dims):
            return ""
        if len(dims) > 2:
            return self.shape_values(chars, dims)
        m, n = dims
        if m == 1:
            return "".join(chars)
        return ["".join(chars[i + j * m] for j in range(n)) for i in range(m)]

    def shape_struct(self, elems, fields, dims):
        if any(d == 0 for d in dims):
            return None
        total = len(elems)
        if total == 1 and len(dims) == 2:
            return record(elems[0])
        vector = len(dims) == 2 and (dims[0] == 1 or dims[1] == 1)
        if vector:
            return table(fields,
                         [[el[f] for f in fields] for el in elems])
        cols = ["D%d" % (i + 1) for i in range(len(dims))] + fields
        rows = []
        idx = [1] * len(dims)
        for el in elems:
            rows.append(list(idx) + [el[f] for f in fields])
            for i in range(len(dims)):
                idx[i] += 1
                if idx[i] <= dims[i]:
                    break
                idx[i] = 1
        return table(cols, rows)

    def read_sparse(self, buf, p, dims, nzmax, is_complex, is_logical):
        mdtype, ir_payload, p = self.read_element(buf, p)
        ir = self.numbers(mdtype, ir_payload)
        mdtype, jc_payload, p = self.read_element(buf, p)
        jc = self.numbers(mdtype, jc_payload)
        mdtype, pr_payload, p = self.read_element(buf, p)
        pr = self.numbers(mdtype, pr_payload)
        pi = None
        if is_complex:
            mdtype, pi_payload, p = self.read_element(buf, p)
            pi = self.numbers(mdtype, pi_payload)
        ncols = dims[1] if len(dims) > 1 else 0
        rows = []
        for j in range(ncols):
            for k in range(jc[j], jc[j + 1]):
                if is_logical:
                    v = pr[k] != 0
                elif is_complex:
                    v = record({"Re": float(pr[k]), "Im": float(pi[k])})
                else:
                    v = float(pr[k])
                rows.append([ir[k] + 1, j + 1, v])
        return table(["Row", "Column", "Value"], rows)


if __name__ == "__main__":
    import json
    import sys
    from pathlib import Path

    for path in sys.argv[1:]:
        doc = parse(Path(path).read_bytes())
        print("==", path)
        print(json.dumps(doc, indent=1, default=str)[:4000])
