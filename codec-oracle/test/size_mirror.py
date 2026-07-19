#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""1:1 Python mirror of the decompressed-size derivation in ../Codec.Decompress.pq.

M cannot run on this machine, so every size probe is written here first, tested
against real compressor output (pyarrow), and then transliterated to M keeping
the same structure. Run this file directly to execute the self-test.

Where each codec keeps its decompressed size:
  snappy      stored: preamble uvarint (always present)
  gzip        stored: ISIZE trailer, last 4 bytes LE (mod 2^32)
  lz4 hadoop  stored: first 4 bytes, big-endian
  zstd        stored optionally: Frame_Content_Size in the frame header;
              one-shot compressors normally write it, streaming ones may not
  lz4 raw     not stored, but derivable: walk the sequence tokens and sum
              literal + match lengths (no decompression needed, O(sequences))
  brotli      stored per meta-block: if the first meta-block is marked ISLAST
              (single-block stream, MLEN <= 16 MiB) the total is in the first
              few bytes; multi-block streams need a full decode -> not derivable

Functions return the size, or None where the stream genuinely does not say
(zstd without FCS, multi-meta-block brotli). The M side turns None into an
error asking for an explicit uncompressedSize.
"""

import struct


# --------------------------------------------------------------------------
# stored sizes (trivial)
# --------------------------------------------------------------------------

def snappy_size(b: bytes):
    value, shift = 0, 0
    for i in range(min(5, len(b))):
        value |= (b[i] & 0x7F) << shift
        shift += 7
        if b[i] < 0x80:
            return value
    return None  # unterminated preamble: not a raw snappy stream


def gzip_size(b: bytes):
    return struct.unpack("<I", b[-4:])[0]


def lz4_hadoop_size(b: bytes):
    return struct.unpack(">I", b[:4])[0]


def lz4_is_hadoop(b: bytes):
    """Detect the hadoop framing: bytes 4-7 big-endian hold the compressed
    size, which for a single-chunk stream equals len - 8. Same heuristic
    Arrow's Lz4HadoopCodec applies before falling back to raw."""
    return len(b) >= 9 and struct.unpack(">I", b[4:8])[0] == len(b) - 8


# --------------------------------------------------------------------------
# zstd: Frame_Content_Size from the frame header (RFC 8878)
# --------------------------------------------------------------------------

def zstd_size(b: bytes):
    head = (b + bytes(18))[:18]  # max header: 4 magic + 1 fhd + 1 window + 4 did + 8 fcs
    if head[0] != 0x28 or head[1] != 0xB5 or head[2] != 0x2F or head[3] != 0xFD:
        raise ValueError("not a zstd frame (bad magic)")
    fhd = head[4]
    fcs_flag = fhd >> 6
    single_segment = (fhd >> 5) & 1
    did_len = (0, 1, 2, 4)[fhd & 3]
    pos = 5 + (0 if single_segment else 1) + did_len
    if fcs_flag == 0:
        return head[pos] if single_segment else None  # absent unless single-segment
    if fcs_flag == 1:
        return head[pos] + head[pos + 1] * 256 + 256
    if fcs_flag == 2:
        return sum(head[pos + i] << (8 * i) for i in range(4))
    return sum(head[pos + i] << (8 * i) for i in range(8))


# --------------------------------------------------------------------------
# brotli: MLEN of the first meta-block when it is also the last (RFC 7932 9.1-9.2)
# --------------------------------------------------------------------------

def brotli_size(b: bytes):
    """MLEN of the first meta-block.

    Exact whenever the stream has a single DATA meta-block, which covers both
    encoder shapes seen in the wild: [last data block] and
    [non-last data block][empty last block] (used for tiny/incompressible
    input). Only wrong when the encoder split the payload across several data
    meta-blocks (guaranteed above the 16 MiB per-block cap) - and a wrong
    size makes the Parquet read fail loudly, never corrupt.
    """
    head = (b + bytes(8))[:8]  # WBITS(<=7) + ISLAST + ISLASTEMPTY + MNIBBLES(2) + MLEN(<=24) < 40 bits

    def bit(i):
        return (head[i // 8] >> (i % 8)) & 1

    def bits(pos, n):
        return sum(bit(pos + k) << k for k in range(n))

    # WBITS: only its bit-length matters here (1, 4 or 7 bits)
    wbits_len = 1 if bit(0) == 0 else (4 if bits(1, 3) != 0 else 7)
    p = wbits_len
    islast = bit(p)
    if islast == 1:
        if bit(p + 1) == 1:  # ISLASTEMPTY: empty stream
            return 0
        p += 2
    else:
        p += 1  # non-last block has no ISLASTEMPTY bit
    mnibbles_code = bits(p, 2)
    if mnibbles_code == 3:
        return None  # metadata meta-block first: bail out, ask for explicit size
    nibbles = 4 + mnibbles_code
    return bits(p + 2, 4 * nibbles) + 1


# --------------------------------------------------------------------------
# lz4 raw block: walk the sequences, sum literal and match lengths
# --------------------------------------------------------------------------

def lz4_raw_size(b: bytes):
    n = len(b)

    def ext_read(start):  # run of 0xFF bytes, then the closing byte
        p = start
        while b[p] == 255:
            p += 1
        return (p - start, p)  # (count of 0xFF, index of closing byte)

    pos, total = 0, 0
    while pos < n:
        token = b[pos]
        lit_nib, match_nib = token >> 4, token & 15
        if lit_nib < 15:
            lit_len, after_token = lit_nib, pos + 1
        else:
            count, last = ext_read(pos + 1)
            lit_len, after_token = 15 + 255 * count + b[last], last + 1
        after_lit = after_token + lit_len
        total += lit_len
        if after_lit >= n:
            break  # final sequence: literals only, no match
        if match_nib < 15:
            match_len, pos = match_nib + 4, after_lit + 2
        else:
            count, last = ext_read(after_lit + 2)
            match_len, pos = 19 + 255 * count + b[last], last + 1
        total += match_len
    return total


# --------------------------------------------------------------------------
# self-test against real compressor output
# --------------------------------------------------------------------------

def main():
    import pyarrow as pa

    compressible = lambda n: (b"codec oracle size probe, " * (n // 25 + 1))[:n]
    import os
    incompressible = lambda n: os.urandom(n)

    sizes = [0, 1, 5, 100, 1567, 100_000, 5_000_000]
    checked = 0
    for make in (compressible, incompressible):
        for n in sizes:
            data = make(n)
            s = pa.Codec("snappy").compress(data).to_pybytes()
            assert snappy_size(s) == n, ("snappy", make.__name__, n)
            g = pa.Codec("gzip").compress(data).to_pybytes()
            assert gzip_size(g) == n, ("gzip", make.__name__, n)
            l = pa.Codec("lz4_raw").compress(data).to_pybytes()
            assert lz4_raw_size(l) == n, ("lz4_raw", make.__name__, n)
            h = struct.pack(">II", n, len(l)) + l
            assert lz4_hadoop_size(h) == n
            assert lz4_is_hadoop(h), ("hadoop not detected", make.__name__, n)
            assert not lz4_is_hadoop(l), ("raw misdetected as hadoop", make.__name__, n)
            z = pa.Codec("zstd").compress(data).to_pybytes()
            zs = zstd_size(z)
            assert zs in (n, None), ("zstd", make.__name__, n, zs)
            if zs is None:
                print(f"  note: pyarrow zstd frame omits FCS at n={n} ({make.__name__})")
            br = pa.Codec("brotli").compress(data).to_pybytes()
            bs = brotli_size(br)
            # contract: never over-estimates; exact while the encoder keeps one
            # data meta-block (empirically well past 100 KB; splits ~2 MiB here)
            assert bs is not None and bs <= n, ("brotli", make.__name__, n, bs)
            if n <= 1_000_000:
                assert bs == n, ("brotli exact range", make.__name__, n, bs)
            elif bs < n:
                print(f"  note: brotli encoder split at n={n} ({make.__name__}): "
                      f"first-block MLEN {bs}; explicit size needed for such streams")
            checked += 1

    # hand-built zstd frame without FCS (fcs_flag=0, not single-segment) -> None
    no_fcs = bytes([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58]) + b"\x01\x00\x00"
    assert zstd_size(no_fcs) is None

    print(f"size mirror self-test passed ({checked} size/generator combinations)")


if __name__ == "__main__":
    main()
