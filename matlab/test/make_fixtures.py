# SPDX-License-Identifier: Apache-2.0
#
# Generates the MATLAB MAT-file v5 fixtures for the Matlab.Document.pq reader.
# Most are written by scipy.io.savemat (the de facto open reference writer);
# a few are hand-crafted byte by byte to exercise corners scipy will not emit
# (numeric storage-type compression, a truly empty file).
#
#   python3 -m venv venv && venv/bin/pip install scipy numpy
#   venv/bin/python make_fixtures.py

import struct
import zlib
from pathlib import Path

import numpy as np
from scipy.io import savemat

HERE = Path(__file__).parent


def save(name, mdict, compress):
    savemat(HERE / name, mdict, format="5", do_compression=compress,
            oned_as="row")


# ---- scalars.mat: one variable per scalar/vector kind, uncompressed ---------
save("scalars.mat", {
    "d_scalar": np.float64(3.14159),
    "i_scalar": np.int32(-42),
    "u8_scalar": np.uint8(200),
    "single_scalar": np.float32(1.5),
    "bool_scalar": np.bool_(True),
    "str_var": "hello world",
    "row_vec": np.array([1.0, 2.0, 3.0, 4.0], dtype=np.float64),
    "col_vec": np.array([[10.0], [20.0], [30.0]], dtype=np.float64),
}, compress=False)

# ---- types.mat: every integer/float class as a small vector -----------------
save("types.mat", {
    "i8": np.array([-128, 0, 127], dtype=np.int8),
    "u8": np.array([0, 128, 255], dtype=np.uint8),
    "i16": np.array([-32768, 0, 32767], dtype=np.int16),
    "u16": np.array([0, 40000, 65535], dtype=np.uint16),
    "i32": np.array([-2147483648, 0, 2147483647], dtype=np.int32),
    "u32": np.array([0, 3000000000, 4294967295], dtype=np.uint32),
    "i64": np.array([-9007199254740000, 0, 9007199254740000], dtype=np.int64),
    "u64": np.array([0, 1, 9007199254740000], dtype=np.uint64),
    "sng": np.array([-1.5, 0.0, 2.25], dtype=np.float32),
    "dbl": np.array([-1.5, 0.0, 2.25], dtype=np.float64),
}, compress=False)

# ---- matrix.mat: 2-D matrices (column-major storage), uncompressed ----------
save("matrix.mat", {
    # 2x3 double: [[1 2 3],[4 5 6]]
    "m_double": np.array([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]),
    # 3x2 int32
    "m_int": np.array([[1, 2], [3, 4], [5, 6]], dtype=np.int32),
    # 3-D 2x2x2
    "m_3d": np.arange(8, dtype=np.float64).reshape(2, 2, 2),
}, compress=False)

# ---- compressed.mat: identical content to matrix.mat but zlib-compressed ----
save("compressed.mat", {
    "m_double": np.array([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]]),
    "m_int": np.array([[1, 2], [3, 4], [5, 6]], dtype=np.int32),
    "greeting": "compressed hello",
}, compress=True)

# ---- struct.mat: scalar struct and struct array -----------------------------
scalar_struct = {"name": "Ada", "age": np.float64(36),
                 "scores": np.array([9.0, 8.5, 7.0])}
struct_array = np.zeros((1, 2), dtype=[("x", object), ("y", object)])
struct_array[0, 0]["x"] = np.float64(1.0)
struct_array[0, 0]["y"] = "first"
struct_array[0, 1]["x"] = np.float64(2.0)
struct_array[0, 1]["y"] = "second"
save("struct.mat", {
    "person": scalar_struct,
    "arr": struct_array,
}, compress=False)

# ---- cell.mat: cell arrays --------------------------------------------------
cell_row = np.empty((1, 3), dtype=object)
cell_row[0, 0] = "alpha"
cell_row[0, 1] = np.float64(42)
cell_row[0, 2] = np.array([1.0, 2.0, 3.0])
cell_col = np.empty((3, 1), dtype=object)
cell_col[0, 0] = "one"
cell_col[1, 0] = "two"
cell_col[2, 0] = "three"
save("cell.mat", {
    "mixed": cell_row,
    "words": cell_col,
}, compress=False)

# ---- complex.mat: complex scalar and matrix ---------------------------------
save("complex.mat", {
    "c_scalar": np.complex128(3 + 4j),
    "c_mat": np.array([[1 + 1j, 2 - 2j], [3 + 0j, 0 + 5j]], dtype=np.complex128),
}, compress=False)

# ---- sparse.mat: sparse matrix ----------------------------------------------
from scipy.sparse import csc_matrix
dense = np.array([[0.0, 0.0, 3.0], [4.0, 0.0, 0.0], [0.0, 0.0, 6.0]])
save("sparse.mat", {"sp": csc_matrix(dense)}, compress=False)

# ---- unicode.mat: char matrix and non-ASCII string --------------------------
save("unicode.mat", {
    "greeting": "café naïve",       # Latin-1 accents -> UTF stored
    "charmat": np.array(["abc", "def"], dtype="U3"),  # 2x3 char matrix
}, compress=False)


# ---- empty.mat: a valid v5 file with zero variables -------------------------
# scipy always writes at least the header; an empty mdict yields a header-only
# file, which is exactly what we want to prove (no variables -> empty nav table).
def write_header_only(path):
    text = b"MATLAB 5.0 MAT-file, hand-crafted empty fixture"
    text = text + b" " * (116 - len(text))
    subsys = b"\x00" * 8
    version = struct.pack("<H", 0x0100)
    endian = b"IM"                      # little-endian indicator
    path.write_bytes(text + subsys + version + endian)


write_header_only(HERE / "empty.mat")


# ---- packed.mat: hand-crafted, double-class array whose data is stored -------
# as int8 (MATLAB's numeric storage compression, which scipy never emits).
# Also exercises the "small data element" tag format for the short name.
def tag(dtype, nbytes):
    return struct.pack("<ii", dtype, nbytes)


def pad8(b):
    r = len(b) % 8
    return b if r == 0 else b + b"\x00" * (8 - r)


def element(dtype, payload):
    return tag(dtype, len(payload)) + pad8(payload)


def small_element(dtype, payload):
    # small data element format: [nbytes:2][dtype:2] then <=4 bytes data,
    # padded to a total of 8 bytes.
    assert len(payload) <= 4
    body = struct.pack("<HH", dtype, len(payload)) + payload
    return body + b"\x00" * (8 - len(body))


def write_packed(path):
    miINT8, miINT32, miUINT32, miMATRIX = 1, 5, 6, 14
    mxDOUBLE = 6
    # array flags: class=mxDOUBLE, flags=0; second word 0
    flags = element(miUINT32, struct.pack("<II", mxDOUBLE, 0))
    # dims: 1x3
    dims = element(miINT32, struct.pack("<iii", 1, 3, 0)[:8])  # only 2 dims
    dims = element(miINT32, struct.pack("<ii", 1, 3))
    # name "p" via small element
    name = small_element(miINT8, b"p")
    # real data: values 10,20,30 stored as int8 though class is double
    pr = element(miINT8, struct.pack("<bbb", 10, 20, 30))
    body = flags + dims + name + pr
    matrix = tag(miMATRIX, len(body)) + body

    text = b"MATLAB 5.0 MAT-file, hand-crafted packed fixture"
    text = text + b" " * (116 - len(text))
    header = text + b"\x00" * 8 + struct.pack("<H", 0x0100) + b"IM"
    path.write_bytes(header + matrix)


write_packed(HERE / "packed.mat")


# ---- widechar.mat: hand-crafted char data stored as miUINT16 (UTF-16) -------
# scipy always writes char data as miUTF8; real MATLAB writes miUINT16.
def write_widechar(path):
    miUINT16, miINT8, miINT32, miUINT32, miMATRIX = 4, 1, 5, 6, 14
    mxCHAR = 4
    s = "Ωmega™"
    flags = element(miUINT32, struct.pack("<II", mxCHAR, 0))
    dims = element(miINT32, struct.pack("<ii", 1, len(s)))
    name = small_element(miINT8, b"wide")
    data = element(miUINT16, s.encode("utf-16-le"))
    body = flags + dims + name + data
    matrix = tag(miMATRIX, len(body)) + body

    text = b"MATLAB 5.0 MAT-file, hand-crafted miUINT16 char fixture"
    text = text + b" " * (116 - len(text))
    header = text + b"\x00" * 8 + struct.pack("<H", 0x0100) + b"IM"
    path.write_bytes(header + matrix)


write_widechar(HERE / "widechar.mat")


# ---- bigend.mat: hand-crafted big-endian ("MI") file ------------------------
# scipy always writes native little-endian; big-endian files come from old
# Solaris/PPC MATLAB. One double matrix, one int16 vector, one miUINT16 char.
def write_bigend(path):
    miUINT16, miINT8, miINT16, miINT32, miUINT32, miDOUBLE, miMATRIX = \
        4, 1, 3, 5, 6, 9, 14
    mxCHAR, mxDOUBLE, mxINT16 = 4, 6, 10

    def btag(dtype, nbytes):
        return struct.pack(">ii", dtype, nbytes)

    def belement(dtype, payload):
        return btag(dtype, len(payload)) + pad8(payload)

    def bsmall(dtype, payload):
        body = struct.pack(">HH", len(payload), dtype) + payload
        return body + b"\x00" * (8 - len(body))

    def bmatrix(klass, dims, name, data_el):
        body = (belement(miUINT32, struct.pack(">II", klass, 0))
                + belement(miINT32, struct.pack(">" + "i" * len(dims), *dims))
                + bsmall(miINT8, name)
                + data_el)
        return btag(miMATRIX, len(body)) + body

    # 2x2 double [[1.5 -2.5],[3.0 4.25]], column-major
    m = bmatrix(mxDOUBLE, (2, 2), b"bd",
                belement(miDOUBLE, struct.pack(">4d", 1.5, 3.0, -2.5, 4.25)))
    v = bmatrix(mxINT16, (1, 3), b"bi",
                belement(miINT16, struct.pack(">3h", -300, 0, 300)))
    c = bmatrix(mxCHAR, (1, 3), b"bc",
                belement(miUINT16, "abΩ".encode("utf-16-be")))

    text = b"MATLAB 5.0 MAT-file, hand-crafted big-endian fixture"
    text = text + b" " * (116 - len(text))
    header = text + b"\x00" * 8 + struct.pack(">H", 0x0100) + b"MI"
    path.write_bytes(header + m + v + c)


write_bigend(HERE / "bigend.mat")

print("wrote fixtures:")
for p in sorted(HERE.glob("*.mat")):
    print(f"  {p.name:16} {p.stat().st_size:6} bytes")
