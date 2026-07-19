# Stata dataset reader

Reads Stata datasets (`.dta`) in pure Power Query M. No Stata licence, no R,
no Python interpreter, no ODBC driver.

Power BI has no native Stata connector. The usual answers are an R or Python
script step (which needs a configured interpreter and rules out most Service
refresh scenarios) or exporting to CSV from a Stata licence someone else owns.
Research data from economics departments, public health bodies, national
statistics offices and NGO monitoring teams ships as `.dta`; this reader parses
the file format directly, so there is nothing to install.

The differentiator is the metadata, not the rectangle. A Stata dataset carries
a data dictionary — variable labels, named value-label sets, display formats,
a sort order — and 27 distinct missing-value codes per numeric type. A reader
that hands back only the stored numbers silently averages the missing codes
into the data (they sit at the top of each numeric range, so the damage is
large and quiet). This reader decodes all of it.

## Usage

Paste [`Stata.Document.pq`](Stata.Document.pq) into a blank query and name the
query `Stata.Document`. Then:

```m
let
    Source = File.Contents("C:\data\survey.dta"),
    Doc    = Stata.Document(Source),
    Data   = Doc{[Name = "Data"]}[Data]
in
    Data
```

The result is a navigation table with three rows:

| Row | Contents |
|---|---|
| `Data` | The observations, one column per variable, typed |
| `Variables` | The data dictionary: position, name, label, storage type, display format, value-label set |
| `ValueLabels` | One row per (variable, value, label) — the code lists |

File-level metadata (format release, byte order, dataset label, timestamp,
observation count, variable count, sort order, encoding) is attached as table
metadata on the navigation table (`Stata.Release`, `Stata.DatasetLabel`, …).

To decode the value labels straight into the data:

```m
Stata.Document(Source, [ApplyValueLabels = true])
```

### Options

Second argument, optional record, all keys optional:

| Key | Default | Effect |
|---|---|---|
| `ApplyValueLabels` | `false` | Replace coded values with their labels in `Data`; unlabeled values pass through; a labeled extended missing shows its label |
| `ExtendedMissingToText` | `false` | The extended missing codes `.a`-`.z` become the texts `".a"`-`".z"` instead of null (`.` is always null) |
| `Encoding` | per format | `TextEncoding` or codepage number; the default is UTF-8 for formats 118/119 and Windows-1252 for older formats |
| `MaxRows` | all observations | Stop after N observations |
| `Strict` | `false` | Error on tolerated malformations (a strL pointer with no backing GSO, a truncated value-label trailer) |

## Supported

- `.dta` formats 113, 114, 115 (Stata 8-12), 117 (Stata 13), 118 (Stata 14-19)
  and 119 (Stata 15-19, more than 32,767 variables).
- Both byte orders — LSF (every file written this century) and MSF (old
  Solaris/AIX Stata). ReadStat, the reference C library, rejects modern
  big-endian files; this reader byte-swaps them.
- All five numeric storage types (`byte`, `int`, `long`, `float`, `double`)
  with the full missing-value scheme: `.` and the extended codes `.a`-`.z`,
  encoded at the top of each numeric range.
- `str#` fixed strings (trailing spaces preserved — they are significant in
  Stata) and `strL` long strings, including cross-linked, empty and binary
  GSOs.
- Value labels, including labels attached to extended missing codes; variable
  labels; the dataset label and timestamp; the sort order.
- Date and time display formats decode to M types: `%td` (and old-style `%d`)
  to `date`; `%tc`/`%tC` to `datetime`; `%tm`, `%tq`, `%th`, `%tw` to the
  `date` their period starts on. The Stata epoch is 1960-01-01.
- Characteristics and expansion fields are skipped structurally (by walking
  their declared lengths, never by scanning for a close tag).

## Type mapping

| Stata | M |
|---|---|
| `byte`, `int`, `long` | `Int64.Type` |
| `float`, `double` | `number` |
| `str#`, `strL` | `text` |
| `%td`, `%tm`, `%tq`, `%th`, `%tw` formats | `date` |
| `%tc`, `%tC` formats | `datetime` |
| `.` and (by default) `.a`-`.z` | `null` |

## Limitations

- **Formats written by Stata 7 or older** (releases 102-112) produce a clear
  error naming the version. Re-save with Stata 8+ or another tool.
- **Formats 120/121** (alias variables, Stata 18+) produce a clear error.
  Stata only writes them when a dataset actually contains alias variables.
- **`%tC` (leap-second) values** are decoded like `%tc`; leap seconds are not
  subtracted, so values drift up to 27 seconds from the calendar time.
- **`%ty` and `%tb` (business calendar) values** stay numeric — the year
  number as-is; business calendars need a calendar file the dataset does not
  contain.
- **Frames, aliases, and `.dtas` bundles** are out of scope; one `.dta` is one
  dataset.
- **Memory.** The whole file is buffered; peak memory is a multiple of file
  size. Fine for research datasets, not for multi-GB extracts.
- **Precision.** M numbers are doubles. `byte`/`int`/`long`/`float` round-trip
  exactly; `double` is the native representation — no loss anywhere.

## How it works

Formats 117+ are a tag-delimited container: `<stata_dta>` wraps a header, a
`<map>` of 14 file offsets, fixed-width dictionary arrays (types, names,
formats, label names, labels), the fixed-width row-major `<data>` rectangle,
a `<strls>` table of GSOs, and `<value_labels>`. The reader follows the map,
so characteristics never need scanning. Formats 113-115 are the same idea
without tags: a 109-byte header, the same dictionary arrays at fixed widths,
5-byte-headed expansion fields, the rectangle, then value-label tables to
end of file.

A strL cell in the rectangle is an 8-byte (v,o) pointer — split 4+4 in
format 117, 2+6 in 118, 3+5 in 119 — into the GSO table, which stores each
long string once; many cells may point at one GSO, and (0,0) means the empty
string. Missing values are ordinary numbers at the top of each type's range:
for `double`, `.` is exactly 2^1023 and `.a`-`.z` follow in steps of 2^1011,
so the reader compares against those constants rather than bit patterns.

The format is fully documented by StataCorp (`help dta` inside Stata, or the
same pages on stata.com), which makes `.dta` the best-specified format in the
statistical trio.

## Testing

Fixtures in [`test/`](test/) are small, synthetic, and generated by
[`test/make_fixtures.py`](test/make_fixtures.py); [`test/expected.md`](test/expected.md)
describes what each one proves and the exact expected output. The decode logic
has been verified cell-by-cell against pandas and pyreadstat (ReadStat) on
every fixture, including two hand-crafted files no library can write: a
big-endian format-118 file with a binary GSO and a label on an extended
missing code, and a legacy codepage-1252 format-114 file with expansion
fields.
