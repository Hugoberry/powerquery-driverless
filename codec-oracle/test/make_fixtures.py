#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fixture generator for the Parquet codec-oracle probe.

Hypothesis: the mashup engine ships Snappy/Brotli/Zstd/LZ4 codecs (Parquet.Document
reads files using them) even though Binary.Decompress refuses everything but
GZip/Deflate. If true, a minimal hand-rolled Parquet wrapper turns Parquet.Document
into a general-purpose decompression oracle callable from pure M.

The wrapper trick: schema = one REQUIRED FIXED_LEN_BYTE_ARRAY(N) column, one row,
PLAIN encoding. PLAIN encoding of a single FLBA value is the raw N bytes with no
length prefix, and a REQUIRED top-level column has no definition/repetition levels,
so the uncompressed form of the data page is *exactly* the payload. That means the
compressed page can be any pre-existing codec stream (an ORC block, an Avro block,
a .snappy file) byte-for-byte -- we never need to re-compress anything.

Outputs (this folder):
  payload.csv               the plaintext payload
  payload.csv.<codec>       raw codec streams of payload.csv (.snappy, .gz, .br,
                            .zst, .lz4raw, .lz4hadoop): inputs for exercising
                            Codec.Decompress and its size derivation per codec
  A_<codec>.parquet         pyarrow-written ordinary Parquet files, one binary column
                            "payload", one row (controls: does Parquet.Document
                            support the codec at all on real-world files)
  B_<codec>.parquet         hand-rolled FLBA wrapper around a real codec stream
                            (the actual test: arbitrary blob in, payload out)
  expected.md               what each fixture proves + sha256s

Every B fixture is round-tripped through pyarrow as a reference reader before it
is accepted. m_mirror_wrapper() re-builds each wrapper with the hardcoded
field-header bytes the M implementation uses (../Codec.Decompress.pq) and asserts
byte equality with the generic thrift builder, so the .pq layout is validated here
even though M cannot run on a non-Windows machine.
"""

import hashlib
import struct
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

HERE = Path(__file__).parent
FIX = HERE  # fixtures sit flat next to this script, matching <format>/test/ convention

# --------------------------------------------------------------------------
# payload
# --------------------------------------------------------------------------

def make_payload() -> bytes:
    rows = ["id,region,amount,comment"]
    for i in range(1, 41):
        rows.append(f"{i},region-{i % 4},{i * 100},codec oracle test row")
    return ("\n".join(rows) + "\n").encode("utf-8")


# --------------------------------------------------------------------------
# thrift compact protocol writer (only what parquet metadata needs)
# --------------------------------------------------------------------------

CT_I32, CT_I64, CT_BINARY, CT_LIST, CT_STRUCT = 5, 6, 8, 9, 12


def uvarint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def zigzag(n: int) -> int:
    return (n << 1) if n >= 0 else ((-n) << 1) - 1


class TStruct:
    def __init__(self):
        self.buf = bytearray()
        self.last = 0

    def _hdr(self, fid: int, ctype: int):
        delta = fid - self.last
        assert 1 <= delta <= 15, "short-form field headers only"
        self.buf.append((delta << 4) | ctype)
        self.last = fid

    def i32(self, fid, v):
        self._hdr(fid, CT_I32)
        self.buf += uvarint(zigzag(v))

    def i64(self, fid, v):
        self._hdr(fid, CT_I64)
        self.buf += uvarint(zigzag(v))

    def string(self, fid, s):
        b = s.encode("utf-8")
        self._hdr(fid, CT_BINARY)
        self.buf += uvarint(len(b)) + b

    def struct(self, fid, s: "TStruct"):
        self._hdr(fid, CT_STRUCT)
        self.buf += s.end()

    def tlist(self, fid, etype, items):
        self._hdr(fid, CT_LIST)
        assert len(items) < 15
        self.buf.append((len(items) << 4) | etype)
        for it in items:
            self.buf += it
    def end(self) -> bytes:
        return bytes(self.buf) + b"\x00"


# --------------------------------------------------------------------------
# minimal parquet wrapper: one row, one REQUIRED FIXED_LEN_BYTE_ARRAY column
# --------------------------------------------------------------------------

# parquet.thrift enums
DATA_PAGE = 0
PLAIN, RLE = 0, 3
FLBA = 7
REQUIRED = 0

CODEC_IDS = {
    "uncompressed": 0,
    "snappy": 1,
    "gzip": 2,
    "brotli": 4,
    "lz4hadoop": 5,
    "zstd": 6,
    "lz4raw": 7,
}


def page_header(usize: int, csize: int) -> bytes:
    dph = TStruct()
    dph.i32(1, 1)        # num_values
    dph.i32(2, PLAIN)    # encoding
    dph.i32(3, RLE)      # definition_level_encoding (unused: max level 0)
    dph.i32(4, RLE)      # repetition_level_encoding (unused)
    ph = TStruct()
    ph.i32(1, DATA_PAGE)
    ph.i32(2, usize)
    ph.i32(3, csize)
    ph.struct(5, dph)
    return ph.end()


def file_metadata(codec_id: int, usize: int, csize: int, ph_len: int) -> bytes:
    root = TStruct()
    root.string(4, "schema")
    root.i32(5, 1)                       # num_children

    col = TStruct()
    col.i32(1, FLBA)
    col.i32(2, usize)                    # type_length
    col.i32(3, REQUIRED)
    col.string(4, "payload")

    cmd = TStruct()
    cmd.i32(1, FLBA)
    cmd.tlist(2, CT_I32, [uvarint(zigzag(PLAIN)), uvarint(zigzag(RLE))])
    cmd.tlist(3, CT_BINARY, [uvarint(7) + b"payload"])
    cmd.i32(4, codec_id)
    cmd.i64(5, 1)                        # num_values
    cmd.i64(6, ph_len + usize)           # total_uncompressed_size
    cmd.i64(7, ph_len + csize)           # total_compressed_size
    cmd.i64(9, 4)                        # data_page_offset

    cc = TStruct()
    cc.i64(2, 4)                         # file_offset
    cc.struct(3, cmd)

    rg = TStruct()
    rg.tlist(1, CT_STRUCT, [cc.end()])
    rg.i64(2, ph_len + csize)            # total_byte_size
    rg.i64(3, 1)                         # num_rows

    fmd = TStruct()
    fmd.i32(1, 1)                        # version
    fmd.tlist(2, CT_STRUCT, [root.end(), col.end()])
    fmd.i64(3, 1)                        # num_rows
    fmd.tlist(4, CT_STRUCT, [rg.end()])
    fmd.string(6, "powerquery-driverless codec oracle")
    return fmd.end()


def build_wrapper(blob: bytes, codec_id: int, usize: int) -> bytes:
    ph = page_header(usize, len(blob))
    meta = file_metadata(codec_id, usize, len(blob), len(ph))
    return b"PAR1" + ph + blob + meta + struct.pack("<I", len(meta)) + b"PAR1"


# --------------------------------------------------------------------------
# mirror of the M implementation (hardcoded field-header bytes, as in the .pq)
# --------------------------------------------------------------------------

def m_mirror_wrapper(blob: bytes, codec_id: int, usize: int) -> bytes:
    """1:1 transliteration of BuildWrapper in Codec.Decompress.pq."""
    z = lambda n: uvarint(zigzag(n))
    csize = len(blob)
    ph = (
        b"\x15" + z(0)          # 1: type = DATA_PAGE
        + b"\x15" + z(usize)    # 2: uncompressed_page_size
        + b"\x15" + z(csize)    # 3: compressed_page_size
        + b"\x2c"               # 5: data_page_header (struct, delta 2)
        + b"\x15" + z(1)        #   1: num_values
        + b"\x15" + z(0)        #   2: encoding = PLAIN
        + b"\x15" + z(3)        #   3: definition_level_encoding = RLE
        + b"\x15" + z(3)        #   4: repetition_level_encoding = RLE
        + b"\x00"               # end data_page_header
        + b"\x00"               # end PageHeader
    )
    ph_len = len(ph)
    root = b"\x48" + uvarint(6) + b"schema" + b"\x15" + z(1) + b"\x00"
    col = (
        b"\x15" + z(7)          # 1: type = FIXED_LEN_BYTE_ARRAY
        + b"\x15" + z(usize)    # 2: type_length
        + b"\x15" + z(0)        # 3: repetition_type = REQUIRED
        + b"\x18" + uvarint(7) + b"payload"
        + b"\x00"
    )
    cmd = (
        b"\x15" + z(7)                       # 1: type
        + b"\x19\x25" + z(0) + z(3)          # 2: encodings = [PLAIN, RLE]
        + b"\x19\x18" + uvarint(7) + b"payload"  # 3: path_in_schema
        + b"\x15" + z(codec_id)              # 4: codec
        + b"\x16" + z(1)                     # 5: num_values
        + b"\x16" + z(ph_len + usize)        # 6: total_uncompressed_size
        + b"\x16" + z(ph_len + csize)        # 7: total_compressed_size
        + b"\x26" + z(4)                     # 9: data_page_offset (delta 2)
        + b"\x00"
    )
    cc = b"\x26" + z(4) + b"\x1c" + cmd + b"\x00"
    rg = b"\x19\x1c" + cc + b"\x16" + z(ph_len + csize) + b"\x16" + z(1) + b"\x00"
    created = "powerquery-driverless codec oracle".encode()
    fmd = (
        b"\x15" + z(1)
        + b"\x19\x2c" + root + col
        + b"\x16" + z(1)
        + b"\x19\x1c" + rg
        + b"\x28" + uvarint(len(created)) + created
        + b"\x00"
    )
    return b"PAR1" + ph + blob + fmd + struct.pack("<I", len(fmd)) + b"PAR1"


# --------------------------------------------------------------------------
# fixture generation
# --------------------------------------------------------------------------

def sha256(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def main():
    FIX.mkdir(parents=True, exist_ok=True)
    payload = make_payload()
    usize = len(payload)
    (FIX / "payload.csv").write_bytes(payload)

    lines = []
    lines.append("# codec-oracle fixtures\n")
    lines.append(f"Generated by make_fixtures.py with pyarrow {pa.__version__}. "
                 f"Payload: payload.csv, {usize} bytes, sha256 {sha256(payload)}.\n")

    # ---- compressed streams (real compressor output via pyarrow) ----------
    streams = {
        "uncompressed": payload,
        "snappy": pa.Codec("snappy").compress(payload).to_pybytes(),
        "gzip": pa.Codec("gzip").compress(payload).to_pybytes(),
        "brotli": pa.Codec("brotli").compress(payload).to_pybytes(),
        "zstd": pa.Codec("zstd").compress(payload).to_pybytes(),
        "lz4raw": pa.Codec("lz4_raw").compress(payload).to_pybytes(),
    }
    # parquet codec 5 (LZ4) is the hadoop framing: 4B BE usize + 4B BE csize + block
    streams["lz4hadoop"] = struct.pack(">II", usize, len(streams["lz4raw"])) + streams["lz4raw"]

    # ---- raw codec streams: direct inputs for Codec.Decompress ------------
    stream_files = {
        "snappy": ("payload.csv.snappy", "Codec.Decompress(blob, Compression.Snappy)"),
        "gzip": ("payload.csv.gz", "Codec.Decompress(blob, Compression.GZip)"),
        "brotli": ("payload.csv.br", "Codec.Decompress(blob, Compression.Brotli)"),
        "zstd": ("payload.csv.zst", "Codec.Decompress(blob, Compression.Zstandard)"),
        "lz4raw": ("payload.csv.lz4raw", "Codec.Decompress(blob, Compression.LZ4)"),
        "lz4hadoop": ("payload.csv.lz4hadoop",
                      "Codec.Decompress(blob, Compression.LZ4)  // hadoop framing auto-detected"),
    }
    lines.append("\n## Raw codec streams\n")
    lines.append("One compressed copy of payload.csv per codec, real compressor output. "
                 "Feed each to Codec.Decompress WITHOUT an uncompressedSize argument: "
                 "every one of these streams lets the size be derived, so the call "
                 "doubles as a test of the per-codec size derivation. The result must "
                 "equal payload.csv byte for byte.\n")
    for name, (fname, call) in stream_files.items():
        blob = streams[name]
        (FIX / fname).write_bytes(blob)
        lines.append(f"- `{fname}`: {len(blob)} bytes, sha256 {sha256(blob)}, `{call}`")

    # ---- A series: ordinary pyarrow-written parquet, one binary column ----
    table = pa.table({"payload": pa.array([payload], type=pa.binary())})
    a_codecs = ["NONE", "SNAPPY", "GZIP", "BROTLI", "ZSTD", "LZ4"]
    lines.append("\n## A series: ordinary Parquet files written by pyarrow\n")
    lines.append("Control: does Parquet.Document read a real-world file with this codec at all.\n")
    for c in a_codecs:
        path = FIX / f"A_{c.lower()}.parquet"
        pq.write_table(table, path, compression=c, use_dictionary=False,
                       write_statistics=False)
        meta = pq.ParquetFile(path).metadata.row_group(0).column(0)
        got = pq.read_table(path)["payload"][0].as_py()
        assert got == payload, f"A_{c} failed pyarrow roundtrip"
        lines.append(f"- `{path.name}`: codec written as {meta.compression}, "
                     f"{path.stat().st_size} bytes, sha256 {sha256(path.read_bytes())}")

    # ---- B series: hand-rolled FLBA wrapper around an arbitrary stream ----
    lines.append("\n## B series: hand-rolled single-cell FLBA wrapper\n")
    lines.append("The compressed page IS the codec stream, byte for byte. This is the "
                 "oracle test: if Parquet.Document returns the payload, the engine "
                 "decompressed an arbitrary external blob.\n")
    for name, blob in streams.items():
        wrapper = build_wrapper(blob, CODEC_IDS[name], usize)
        path = FIX / f"B_{name}.parquet"
        path.write_bytes(wrapper)
        got = pq.read_table(path)["payload"][0].as_py()
        assert got == payload, f"B_{name} failed pyarrow roundtrip"
        lines.append(f"- `{path.name}`: codec id {CODEC_IDS[name]}, blob {len(blob)} bytes, "
                     f"file {len(wrapper)} bytes, sha256 {sha256(wrapper)}")

    # ---- mirror check: M transliteration must match the generic builder ---
    for name, blob in streams.items():
        a = build_wrapper(blob, CODEC_IDS[name], usize)
        b = m_mirror_wrapper(blob, CODEC_IDS[name], usize)
        assert a == b, f"M mirror diverges from thrift builder for {name}"
    lines.append("\nMirror check passed: the hardcoded-byte construction used by "
                 "Codec.Decompress.pq reproduces every B file byte-for-byte.\n")

    lines.append("\n## What each result would mean\n")
    lines.append("- A fails, B fails: codec genuinely absent from the engine.")
    lines.append("- A works, B fails: codec present but the wrapper is malformed for "
                 "Microsoft's reader (fix the wrapper; the codec claim still stands).")
    lines.append("- A works, B works: Parquet.Document is a decompression oracle for "
                 "this codec; any format compressing its blocks with it becomes "
                 "readable in pure M.")
    lines.append("- B_uncompressed and B_gzip are wrapper sanity controls: gzip is "
                 "known-implemented, so if B_gzip fails the wrapper is wrong, not the codec.\n")

    (FIX / "expected.md").write_text("\n".join(lines))
    print(f"payload: {usize} bytes")
    for k, v in streams.items():
        print(f"stream {k}: {len(v)} bytes")
    print("all pyarrow roundtrips + mirror checks passed")
    print(f"fixtures in {FIX}")


if __name__ == "__main__":
    main()
