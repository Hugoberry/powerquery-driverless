# codec-oracle

**Snappy, Brotli, Zstandard and LZ4 decompression in pure Power Query M.**

`Binary.Decompress` implements exactly two of the seven members on the `Compression.Type` enum: GZip and Deflate. Ask it for Snappy, Brotli, LZ4 or Zstandard and it fails at runtime, even though the enum declares them.

The engine contains all of those codecs anyway. `Parquet.Document` uses them every time it reads a compressed Parquet file. `Codec.Decompress` makes them callable from plain M by wrapping an arbitrary compressed stream in a minimal, spec-conformant Parquet file and letting `Parquet.Document` do the work. That construction is the "oracle": a documented API repurposed, through nothing but valid inputs, to compute something the standard library does not expose.

## Usage

Paste [`Codec.Decompress.pq`](Codec.Decompress.pq) into a blank query and name the query `Codec.Decompress`. The argument convention mirrors `Binary.Decompress`:

```m
// the decompressed size is derived from the stream itself for every codec
Codec.Decompress(File.Contents("C:\data\block.snappy"), Compression.Snappy)
Codec.Decompress(blob, Compression.Zstandard)
Codec.Decompress(blob, Compression.Brotli)

// LZ4 raw blocks and hadoop-framed LZ4 both work; the framing is auto-detected
Codec.Decompress(blob, Compression.LZ4)

// gzip and deflate are routed straight to Binary.Decompress
Codec.Decompress(blob, Compression.GZip)

// third argument overrides the derivation, for the streams that need it
Codec.Decompress(blob, Compression.Zstandard, 1048576)

// fourth argument forces an LZ4 framing if auto-detection ever guesses wrong
Codec.Decompress(blob, Compression.LZ4, null, [LZ4Framing = "Raw"])
```

The wrapper has to declare the decompressed size, so `Codec.Decompress` reads it out of the stream:

| Compression.Type | Wire format expected | Where the size comes from |
|---|---|---|
| `Compression.Snappy` | raw snappy block | stored: preamble varint |
| `Compression.Brotli` | raw brotli stream | stored: first meta-block MLEN (see caveat below) |
| `Compression.Zstandard` | zstd frame | stored: frame content size, when the frame declares it |
| `Compression.LZ4` | LZ4 raw block or hadoop-framed, auto-detected | hadoop: stored in the header; raw: derived by a walk over the sequence tokens, no decompression |
| `Compression.GZip` | gzip stream | not needed (native path) |
| `Compression.Deflate` | raw deflate | not needed (native path) |
| `Compression.None` | anything | returned unchanged |

Two streams can genuinely withhold the size, and both produce a clear error asking for an explicit `uncompressedSize`: a zstd frame written without the optional content-size field (some streaming compressors), and a brotli stream the encoder split into several meta-blocks (typically inputs beyond a couple of MB; the first block's MLEN covers everything smaller). A wrong or stale size can never corrupt output: the Parquet reader checks it and the read fails loudly.

LZ4 framing detection: a hadoop-framed stream carries its compressed size at bytes 4-7 big-endian, so a stream whose bytes 4-7 equal its own length minus 8 is treated as hadoop-framed (the same heuristic Arrow's hadoop-LZ4 codec uses). Pass `[LZ4Framing = "Raw"]` or `"Hadoop"` to force it in the astronomically unlikely event a raw block matches the pattern by chance.

Framed container formats are not handled directly: a snappy framing-format file (`sNaPpY` magic) or an LZ4 frame is a sequence of blocks with chunk headers. Split the frame with ordinary M byte work and feed each block through `Codec.Decompress`.

The optional fourth argument also accepts `[ReturnWrapper = true]`, which returns the generated Parquet bytes instead of parsing them. Useful for debugging against the reference fixtures in [`test/`](test/).

Readers in this repo follow a one-file, paste-and-go rule, so a reader that needs one of these codecs inlines this function into its own `.pq` rather than referencing it across queries. This folder holds the canonical copy, the tests and the documentation.

## How it works

A Parquet data page is compressed as a single unit, and the codec is named in the file's metadata. `Codec.Decompress` builds, in memory, a Parquet file whose schema is one `REQUIRED FIXED_LEN_BYTE_ARRAY(N)` column holding one row with PLAIN encoding. That schema is the unique point in Parquet's design space where the uncompressed form of the data page is exactly the N payload bytes: REQUIRED removes definition and repetition levels, a single row removes repetition, and the fixed-length type removes the per-value length prefixes a normal byte-array column would inject.

Because of that, the compressed page can be your stream, byte for byte, with no re-encoding. The function assembles the page header and footer metadata (Thrift compact protocol, about 150 lines of `Binary.Combine`), hands the result to `Parquet.Document`, and reads the single cell back: your decompressed bytes.

```
PAR1 | page header | your compressed stream | file metadata | footer length | PAR1
```

Everything is standard library M. No custom connector, no external calls, and the data never leaves the mashup engine.

## Verifying on your host

Codec availability lives in the host's `Parquet.Document` implementation, so it can vary by product and build. [`Codec.Probe.pq`](Codec.Probe.pq) checks all of it in one shot: point it at a copy of the [`test/`](test/) folder and it returns a table of every fixture with OK / MISMATCH / ERROR per file.

```m
Codec.Probe("C:\path\to\codec-oracle\test")
```

The `A_*` fixtures are ordinary Parquet files (is the codec supported at all); the `B_*` fixtures are oracle wrappers around raw codec streams (does the arbitrary-blob path work). `B_gzip` and `B_uncompressed` are sanity controls: gzip is implemented everywhere, so if those fail the wrapper is being rejected, not the codec.

The `payload.csv.*` files are raw compressed streams of the same payload, one per codec (`.snappy`, `.gz`, `.br`, `.zst`, `.lz4raw`, `.lz4hadoop`). Feed them to `Codec.Decompress` without an `uncompressedSize` argument: each call exercises that codec's size derivation end to end, and the result must equal `payload.csv` byte for byte. The exact call for each file is listed in [`test/expected.md`](test/expected.md).

Status: all seven codecs confirmed working in Power BI Desktop (July 2026). Results for the Service, Excel and Dataflow Gen2 are welcome; note that `Parquet.Document` itself is not available in every host.

## Limitations

- The whole stream and its decompressed form are in memory; this is a property of M, not of the wrapper.
- Each call is a full `Parquet.Document` invocation. Negligible for file-sized payloads; if you are decompressing thousands of small blocks, measure first.
- The raw-LZ4 size derivation scans the block token by token in interpreted M. Fast enough for ordinary blocks; for very large ones, passing `uncompressedSize` skips the scan.
- Trailing checksums (CRC-32 in framing formats, Adler-32 in zlib) are not validated. Strip container framing before calling, as shown above.
- `Compression.Deflate` has no Parquet codec, so `[ReturnWrapper = true]` is an error for it; the normal path serves it via `Binary.Decompress`.

## Testing

[`test/make_fixtures.py`](test/make_fixtures.py) generates every fixture from scratch: a hand-rolled Parquet writer for the wrappers, real compressor output for the streams, and a byte-level mirror of the M implementation. Each wrapper is round-tripped through two independent readers (pyarrow and DuckDB) before it is accepted, and [`test/expected.md`](test/expected.md) records what each fixture proves along with sha256 hashes. [`test/size_mirror.py`](test/size_mirror.py) is a line-for-line Python mirror of the size-derivation logic, self-tested against real compressor output across sizes from empty to multi-megabyte, compressible and incompressible. Requires Python with `pyarrow`.

## Licence

[Apache License 2.0](../LICENSE), same as the rest of the repo.
