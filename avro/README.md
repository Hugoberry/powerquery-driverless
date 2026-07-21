# Avro OCF reader

Reads Apache Avro Object Container Files (`.avro`) in pure Power Query M. No Java,
no `avro-tools` jar, no Spark cluster, no ODBC driver.

The most common source of these files is Azure itself: Event Hubs Capture and IoT
Hub routing write Avro to Blob Storage by default. Since blob storage is somewhere
the Power BI Service can already reach, these files refresh in the Service with
nothing installed and no gateway at all.

## Usage

Paste [`Avro.Document.pq`](Avro.Document.pq) into a blank query and name the query
`Avro.Document`. Then:

```m
let
    Source = File.Contents("C:\data\capture.avro"),
    Table  = Avro.Document(Source)
in
    Table
```

Or straight from blob storage:

```m
Avro.Document(AzureStorage.Blobs("account"){[Name="container"]}[Data]{0}[Content])
```

The result is a table with one column per field of the top-level record (or a
single `Value` column if the schema is not a record). The Avro schema JSON and
codec are attached as table metadata (`Avro.Schema`, `Avro.Codec`).

### Event Hubs / IoT Hub Capture files

Capture files wrap the actual payload in a `Body` field of type `bytes`. A reader
that hands you a bytes column has not read your data, so `Body` is decoded to UTF-8
text by default. If your payloads are JSON (they usually are):

```m
Avro.Document(Source, [ParseBodyAsJson = true])
```

then expand the `Body` record column. Payloads that are not valid JSON fall back
to text (or error, under `Strict = true`). Use `[KeepBodyBinary = true]` to opt
out and keep the raw bytes.

### Options

Second argument, optional record, all keys optional:

| Key | Default | Effect |
|---|---|---|
| `ParseBodyAsJson` | `false` | Parse a top-level `Body` bytes field with `Json.Document` |
| `KeepBodyBinary` | `false` | Leave `Body` as raw bytes |
| `Encoding` | `TextEncoding.Utf8` | Encoding for the default `Body`-to-text decode |
| `MaxRows` | all rows | Stop after N rows; later blocks are not decoded |
| `Strict` | `false` | Error on tolerated malformations (non-JSON `Body` under `ParseBodyAsJson`, trailing bytes in a data block) |

## Supported

- Codecs: `null`, `deflate`, `snappy`, and `zstandard`.
- All primitive types: `null`, `boolean`, `int`, `long`, `float`, `double`,
  `bytes`, `string`.
- Complex types: records (nested), enums, arrays, maps, unions, fixed.
- Named type references, including recursive schemas (a record referencing
  itself), with namespace resolution.
- Logical types: `decimal` (on bytes/fixed), `date`, `time-millis`,
  `time-micros`, `timestamp-millis`, `timestamp-micros`,
  `local-timestamp-millis`, `local-timestamp-micros`, `uuid`, `duration`.
  Unknown logical types fall back to their base type, as the spec requires.
- Multi-block files, with per-block sync-marker validation.

## Type mapping

| Avro | M |
|---|---|
| `boolean` | `logical` |
| `int`, `long` | `Int64` |
| `float`, `double` | `number` |
| `string`, `enum`, `uuid` | `text` |
| `bytes`, `fixed` | `binary` |
| `decimal` | `number` |
| `date` | `date` |
| `time-millis/micros` | `time` |
| `timestamp-millis/micros` | `datetimezone` (UTC) |
| `local-timestamp-millis/micros` | `datetime` |
| `record` | record |
| `array` | list |
| `map` | record |
| union `["null", X]` | nullable X |
| other unions | untyped (`any`) |
| `duration` | record `[Months, Days, Milliseconds]` |

## Limitations

- **Codecs.** `null` and `deflate` decode natively (`Binary.Decompress`); `snappy`
  and `zstandard` decode through the codec oracle inlined into the reader (a minimal
  in-memory Parquet file handed to `Parquet.Document`, the same trick as
  [`codec-oracle`](../codec-oracle)). `bzip2` and `xz` produce a clear error — the
  engine has no codec for them. Codec availability lives in the host's
  `Parquet.Document`; snappy/zstandard are confirmed in Power BI Desktop.
- **Precision.** M numbers are doubles: `long` values beyond 2^53 lose precision,
  as do decimals whose unscaled value exceeds 2^53.
- **Writer schema only.** The schema embedded in the file is used as-is; schema
  resolution against a separate reader schema is not implemented.
- **OCF only.** Single-object encoding and raw datum streams (schema-less byte
  blobs, e.g. a Kafka message body) are not container files and are not supported.
- **Memory.** The whole file is buffered; peak memory is a multiple of file size.
  Fine for capture-sized files, not for multi-GB archives.
- **CRC.** The snappy codec appends a CRC-32 of the uncompressed block data. Those
  4 bytes are stripped before decoding (they are not part of the snappy stream) but
  the checksum is not validated — the per-block sync marker already catches corruption.

## How it works

An OCF file is a header — magic bytes, a metadata map containing the schema as
JSON and the codec name, a 16-byte sync marker — followed by data blocks of
(object count, byte size, serialized objects, sync marker). It is strictly
sequential, so no seeking is needed.

The reader parses the metadata map at byte level, reads the schema with
`Json.Document`, and compiles it into a `BinaryFormat` parser: varints are read
with `BinaryFormat.List`'s continuation-bit condition and zigzag-decoded, records
become `BinaryFormat.Record`, unions and length-prefixed values use
`BinaryFormat.Choice`, and arrays/maps share Avro's blocked encoding. Named type
references are resolved through a registry at parse time rather than at compile
time, which is what makes recursive schemas terminate. Deflate blocks are raw
RFC 1951 streams, which is exactly what `Binary.Decompress` with
`Compression.Deflate` expects.

## Testing

Fixtures in [`test/`](test/) are small, synthetic, and generated by
[`test/make_fixtures.py`](test/make_fixtures.py); [`test/expected.md`](test/expected.md)
describes what each one proves and the exact expected output. The decode logic has
been verified against fastavro (the Python reference implementation) on every fixture.
