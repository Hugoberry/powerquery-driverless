# crc32

**CRC-32 checksums in pure Power Query M, five variants, no dependencies.**

M's standard library has no hashing at all, yet binary formats are full of CRC-32 fields: gzip stores one in its trailer, zip in every central directory entry, PNG in every chunk, Avro's snappy codec after every compressed block, and the snappy framing format a masked CRC-32C per chunk. `Crc32.Compute` makes those fields checkable instead of skippable.

## Usage

Paste [`Crc32.Compute.pq`](Crc32.Compute.pq) into a blank query and name the query `Crc32.Compute`.

```m
Crc32.Compute(data)                                  // CRC-32, the zlib/gzip/zip/png one
Crc32.Compute(data, "CRC32C")                        // Castagnoli: snappy, iSCSI, ext4
Crc32.Compute(data, "CRC32C", [SnappyMask = true])   // snappy framing-format masked CRC
Number.ToText(Crc32.Compute(data), "X8")             // as the usual 8-digit hex
```

| Variant | Polynomial | Reflected | Final XOR | Seen in |
|---|---|---|---|---|
| `CRC32` (aliases `ISO-HDLC`, `zlib`, `gzip`, `zip`, `png`) | 0x04C11DB7 | yes | 0xFFFFFFFF | gzip, zip, PNG, Avro snappy blocks, Ethernet |
| `CRC32C` (aliases `Castagnoli`, `iSCSI`, `snappy`) | 0x1EDC6F41 | yes | 0xFFFFFFFF | snappy framing, iSCSI, ext4 metadata |
| `JAMCRC` | 0x04C11DB7 | yes | none | some tooling; equals `CRC32` without the final XOR |
| `BZIP2` | 0x04C11DB7 | no | 0xFFFFFFFF | bzip2 |
| `MPEG2` | 0x04C11DB7 | no | none | MPEG transport streams |

Variant names are matched case-insensitively and ignore `-`, `/`, `_` and spaces. `[SnappyMask = true]` applies the snappy framing format's CRC masking (rotate right 15, add 0xA282EAD8) after the checksum; the format specifies it for CRC-32C.

The input is `binary`, deliberately. CRC is defined over bytes, so hashing text means choosing an encoding first: `Crc32.Compute(Text.ToBinary(s, TextEncoding.Utf8))`.

## How it works

The classic table-driven algorithm: a 256-entry lookup table built once from the polynomial (`List.Buffer`ed, so it is computed eagerly and indexed in constant time), then a single `List.Accumulate` pass with one table lookup and three bitwise operations per byte.

Stripped to a single hard-coded variant, the entire algorithm is this:

```m
// minimal CRC-32 (the zlib/gzip/zip/png variant), for reading, not pasting:
// use Crc32.Compute.pq for the real thing
let
    Crc32 = (data as binary) as number =>
    let
        // 256-entry table: the CRC of each possible byte, precomputed by
        // running the polynomial division bit by bit
        Table = List.Buffer(List.Transform({0..255}, (n) =>
            List.Accumulate({0..7}, n, (c, _) =>
                if Number.BitwiseAnd(c, 1) = 1
                then Number.BitwiseXor(Number.BitwiseShiftRight(c, 1), 0xEDB88320)
                else Number.BitwiseShiftRight(c, 1)))),
        // one pass: shift the register a byte to the right and fold in the
        // table entry selected by (register XOR next byte)
        crc = List.Accumulate(Binary.ToList(data), 0xFFFFFFFF, (c, byte) =>
            Number.BitwiseXor(
                Number.BitwiseShiftRight(c, 8),
                Table{Number.BitwiseAnd(Number.BitwiseXor(c, byte), 0xFF)}))
    in
        Number.BitwiseXor(crc, 0xFFFFFFFF)
in
    Crc32
```

That is the whole gist: build the table, fold the bytes, flip the result. Everything else in [`Crc32.Compute.pq`](Crc32.Compute.pq) is bookkeeping around this core: the variant catalog (which polynomial, which initial value, whether to XOR at the end), the mirror-image left-shift engine for the two unreflected variants, alias resolution, and the optional snappy mask. Reflected variants use the right-shift engine shown above with the reflected polynomial; forward variants use the left-shift engine.

One property worth calling out in M specifically: every intermediate value stays below 2^32 by construction. The reflected engine only ever shifts right, and the forward engine masks to 32 bits after every left shift. C implementations get this truncation for free from `uint32`; M has no fixed-width integers, so an unmasked port of C code accumulates unbounded garbage in the high bits and ends up relying on undocumented runtime conversion behavior. This implementation never does.

## Limitations

- Throughput is interpreter-bound, roughly linear in input size. Checking a trailer, a chunk, or a compressed block is instant; hashing hundreds of megabytes is not what M is for.
- Fancier C-side optimizations (slicing-by-4/8) do not pay off in M: they exist to break CPU dependency chains, and the interpreter's per-item overhead dwarfs that effect. One table is the right shape here.

## Testing

[`test/crc_mirror.py`](test/crc_mirror.py) is a line-for-line Python mirror of the M implementation, validated three independent ways: against a bit-by-bit reference implementation (no table), against the published check values (`CRC(b"123456789")`) for all five variants, and against `zlib.crc32` for the default variant. It also checks the internal relations (JAMCRC = CRC32 without final XOR, MPEG2 = BZIP2 without final XOR) and that the snappy mask round-trips. Running it regenerates [`test/sample.bin`](test/sample.bin) and [`test/expected.md`](test/expected.md), which lists every value the M port must reproduce on a real host.

## Licence

[Apache License 2.0](../LICENSE), same as the rest of the repo.
