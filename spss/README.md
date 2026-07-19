# SPSS system file reader

Reads SPSS system files (`.sav`, `.zsav`) in pure Power Query M. No SPSS licence,
no R, no Python interpreter, no ODBC driver.

Power BI has no native SPSS connector. The usual answers are an R or Python
script step (which needs a configured interpreter and rules out most Service
refresh scenarios) or a commercial ODBC driver (which needs an install). Survey
data from national statistics offices, public health bodies, universities and
market research agencies ships as `.sav`; this reader parses the file format
directly, so there is nothing to install.

The differentiator is the metadata, not the rectangle. An SPSS file carries a
data dictionary — variable labels, value labels, user-missing declarations,
measurement levels — and a reader that hands back only the coded numbers is a
worse CSV export. This reader emits all of it.

## Usage

Paste [`Spss.Document.pq`](Spss.Document.pq) into a blank query and name the
query `Spss.Document`. Then:

```m
let
    Source = File.Contents("C:\data\survey.sav"),
    Doc    = Spss.Document(Source),
    Data   = Doc{[Name = "Data"]}[Data]
in
    Data
```

The result is a navigation table with three rows:

| Row | Contents |
|---|---|
| `Data` | The cases, one column per variable, typed |
| `Variables` | The data dictionary: name, label, type, formats, measure, missing declarations |
| `ValueLabels` | One row per (variable, value, label) — the code lists |

File-level metadata (product string, file label, creation date, compression,
codepage, case count, weight variable, document lines) is attached as table
metadata on the navigation table (`Spss.Product`, `Spss.FileLabel`, …).

To decode the value labels straight into the data:

```m
Spss.Document(Source, [ApplyValueLabels = true])
```

and to treat user-missing values the way SPSS does in analysis:

```m
Spss.Document(Source, [UserMissingToNull = true])
```

### Options

Second argument, optional record, all keys optional:

| Key | Default | Effect |
|---|---|---|
| `ApplyValueLabels` | `false` | Replace coded values with their labels in `Data`; unlabeled values pass through |
| `UserMissingToNull` | `false` | Null out values declared user-missing in the dictionary (discrete values and ranges) |
| `Encoding` | from the file | `TextEncoding` or codepage number, overriding the file's declared encoding |
| `MaxRows` | all cases | Stop after N cases |
| `Strict` | `false` | Error on tolerated malformations (trailing partial case, dangling value-label indices, numeric data inside a string) |

## Supported

- `.sav` uncompressed, `.sav` bytecode-compressed (what SPSS writes by default),
  and `.zsav` (zlib), including multi-block zsav.
- Numeric and string variables, including strings wider than 255 bytes
  (reassembled across segments per the PSPP spec).
- Long variable names, variable labels, value labels (including long-string
  value labels), user-missing declarations (discrete values and ranges),
  measurement level, display width, alignment.
- `DATE`/`ADATE`/`EDATE`/`SDATE`/`JDATE`/`QYR`/`MOYR`/`WKYR` decode to `date`,
  `DATETIME`/`YMDHMS` to `datetime`, `TIME`/`DTIME`/`MTIME` to `duration`
  (the SPSS epoch is 1582-10-14, values are seconds).
- Character encoding from the file's declaration — the modern UTF-8 record or
  the legacy machine-record codepage — with `options[Encoding]` as an override.
  Files that declare nothing default to Windows-1252.

## Type mapping

| SPSS | M |
|---|---|
| numeric (`F`, `COMMA`, `E`, …) | `number` |
| string (`A`) | `text` |
| date formats | `date` |
| `DATETIME`, `YMDHMS` | `datetime` |
| time formats | `duration` |
| system-missing | `null` |

## Limitations

- **Big-endian files** (written by pre-2000 SPSS on big-endian UNIX) produce a
  clear error. Little-endian covers everything written this century.
- **EBCDIC files** produce a clear error.
- **Case weights** are reported (`Spss.WeightVariable`) but not applied — every
  case is one row.
- **Memory.** The whole file is buffered; peak memory is a multiple of file
  size. Fine for survey-sized files, not for multi-GB extracts.
- **Precision.** M numbers are doubles, which is also what SPSS stores — no
  loss, but integers beyond 2^53 cannot round-trip exactly in either system.

## How it works

A system file is a 176-byte header, a sequence of dictionary records (variables,
value labels, documents, extension records), a terminator, then the case data.
Every case is a row of 8-byte elements: a numeric variable is one IEEE double, a
string of width w occupies ceil(w/8) elements, and strings wider than 255 are
split into segment variables stitched back together by extension record 14.

The default compression is a bytecode: command bytes 1–251 encode small
integers directly (value = code − bias), 253 marks a literal 8-byte element,
254 a run of spaces, 255 system-missing. `.zsav` wraps that same bytecode
stream in zlib blocks — each block loses its 2-byte zlib header and feeds
`Binary.Decompress` with `Compression.Deflate`, the block-descriptor trailer
saying where each block lives.

The format is documented in detail by the PSPP developers' guide, which is the
de facto specification.

## Testing

Fixtures in [`test/`](test/) are small, synthetic, and generated by
[`test/make_fixtures.py`](test/make_fixtures.py); [`test/expected.md`](test/expected.md)
describes what each one proves and the exact expected output. The decode logic
has been verified cell-by-cell against pyreadstat (ReadStat, the reference
implementation used by R haven) on every fixture, including two hand-crafted
files ReadStat cannot write: a legacy codepage-1252 file and a multi-block zsav.
