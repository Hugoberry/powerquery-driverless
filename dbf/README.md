# dBASE / FoxPro reader

Reads dBASE and FoxPro tables (`.dbf`, with their `.dbt`/`.fpt` memo sidecars)
in pure Power Query M. No Visual FoxPro OLE DB driver, no ODBC, nothing to
install.

Power BI has no native connector for `.dbf`. The blessed path is the Visual
FoxPro OLE DB/ODBC driver: 32-bit only, last shipped in 2007, out of support
since 2015, and an admin install that IT will not approve. Meanwhile the
vertical applications built on FoxPro and dBASE (pharmacy, dental, POS,
logistics, lab instruments, small ERP) are still running and still emit
`.dbf` files onto shares. This reader parses the file format directly, so
there is nothing to install.

## Usage

Paste [`Dbf.Table.pq`](Dbf.Table.pq) into a blank query and name the query
`Dbf.Table`. Then:

```m
let
    Source = File.Contents("C:\data\customers.dbf"),
    Data   = Dbf.Table(Source)
in
    Data
```

Tables with memo fields keep the long text in a sidecar file, `.fpt` for
FoxPro or `.dbt` for dBASE. Pass it as a second binary:

```m
Dbf.Table(File.Contents("C:\data\customers.dbf"),
          [Memo = File.Contents("C:\data\customers.fpt")])
```

Without the sidecar, memo columns come back as nulls (an error under
`[Strict = true]`); the reader never silently drops them.

### Options

Second argument, optional record, all keys optional:

| Key | Default | Effect |
|---|---|---|
| `Memo` | none | The `.fpt` / `.dbt` memo sidecar as a binary |
| `Encoding` | from the file | Codepage number or `TextEncoding` value, overriding the file's language-driver byte |
| `IncludeDeleted` | `false` | Keep records flagged as deleted and append a `_Deleted` logical column |
| `MaxRows` | all | Stop after N rows |
| `Strict` | `false` | Error on tolerated malformations (bad numerics, dates or logicals; truncated record area; memo pointers with no sidecar provided) |

Header facts are attached as metadata on the returned table:
`Dbf.Version`, `Dbf.Dialect`, `Dbf.Codepage`, `Dbf.LastUpdate`,
`Dbf.RecordCount`.

## Supported

- dBASE III/IV/5 (version bytes 0x03, 0x83, 0x8B and friends), FoxBASE,
  FoxPro 2.x (0xF5) and Visual FoxPro (0x30/0x31/0x32).
- All three memo sidecar layouts: dBASE III (512-byte blocks, 0x1A
  terminator), dBASE IV (length-prefixed entries) and FoxPro `.fpt` (typed
  entries, block size from the header); text memos decode with the table's
  codepage, binary memos stay binary.
- Visual FoxPro extras: `_NullFlags` (hidden, decoded, never shown as a
  column), Varchar/Varbinary actual lengths, the header backlink, int32,
  double, currency and datetime fields.
- Deleted-record flags (skipped by default, kept with `IncludeDeleted`).
- Language-driver codepages (DOS and Windows, western and eastern European,
  Cyrillic, Greek, Turkish, Baltic, Hebrew, Arabic, CJK, Thai), with 1252 as
  the fallback when the file declares nothing.
- Dialect quirks: Char fields wider than 255 bytes (length carried in the
  decimal-count byte) and comma decimal separators in numerics.

## Type mapping

| DBF | M |
|---|---|
| `C` character, `V` varchar, `M` memo | `text` |
| `N` numeric (0 decimals), `I` integer, `+` autoincrement | `Int64.Type` |
| `N` numeric (with decimals), `F` float, `B` double (VFP) | `number` |
| `Y` currency | `Currency.Type` |
| `D` date | `date` |
| `T` datetime | `datetime` |
| `L` logical | `logical` (`?` and blank are `null`) |
| `Q` varbinary, `G` general, `P` picture, `W` blob, binary memo | `binary` |
| blank / null-flagged | `null` |

## Limitations

- **dBASE Level 7** (version bytes 0x04/0x8C) uses a different header layout
  and produces a clear error.
- **Encrypted tables** are not detected as such; they decode to garbage the
  way every non-dBASE tool sees them.
- **Index sidecars** (`.mdx`, `.cdx`, `.ntx`) are ignored; they are never
  needed to read the data.
- **Memory.** The whole file is buffered; peak memory is a multiple of file
  size. DBF's 2 GB design ceiling keeps real files well inside that.
- **Precision.** Currency (`Y`) is a scaled 64-bit integer and M numbers are
  doubles, so values beyond 15 significant digits lose precision.

## How it works

A DBF file is a 32-byte header (version byte, record count, header and record
sizes, language-driver byte), an array of 32-byte field descriptors terminated
by 0x0D, then fixed-width records. The first byte of each record is the
deletion flag; every field is a fixed slice of the record, so the whole parse
is sequential arithmetic with no offset tables and no recursion.

Field values are text even when numeric: `N` is a right-justified decimal
string, `D` is `YYYYMMDD`. The FoxPro additions are binary: `I` int32, `B`
double, `Y` int64 scaled by 10^4, `T` a Julian day number plus milliseconds
since midnight. Memo fields store a block pointer into the sidecar file.
Visual FoxPro tracks nulls and varchar lengths in a hidden `_NullFlags`
field, one or two bits per participating field, in field order.

The layouts are documented in Microsoft's Visual FoxPro table-structure
reference and the community xBase file-format writeups; where writers
disagree (dBASE IV memo lengths, wide Char fields), the reader follows what
the surviving reference implementations accept.

## Testing

Fixtures in [`test/`](test/) are small, synthetic, and generated by
[`test/make_fixtures.py`](test/make_fixtures.py);
[`test/expected.md`](test/expected.md) describes what each one proves and the
exact expected output. The decode logic is mirrored in
[`test/mirror.py`](test/mirror.py) and validated by
[`test/check_mirror.py`](test/check_mirror.py) on every fixture, cell by cell
against dbfread (an independent reference reader) and against hand-written
expected values, including two hand-crafted files no open writer can produce:
a dBASE IV memo file and a Visual FoxPro Varchar/Varbinary table.
