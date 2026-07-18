# EVTX reader

Reads Windows XML Event Log files (`.evtx`) in pure Power Query M. No
Windows Event Log API, no log forwarder, no SIEM licence, nothing to
install.

An `.evtx` file is how Windows event logs arrive when someone exports them,
copies `C:\Windows\System32\winevt\Logs`, or collects triage output from an
endpoint. The blessed ways to read one are the Windows event APIs (so a
Windows box with the right locale and providers), PowerShell, or ingesting
it into a SIEM. Power Query has none of these problems: this reader parses
the binary XML directly, so the file can sit in SharePoint, a blob container
or a mailbox attachment and still refresh in the Service. One row per event,
with the fields analytics actually pivots on already extracted.

## Usage

Paste [`Evtx.Document.pq`](Evtx.Document.pq) into a blank query named
`Evtx.Document`. Then:

```m
let
    Source = File.Contents("C:\evidence\Security.evtx"),
    Events = Evtx.Document(Source)
in
    Events
```

The result is a table with one row per event record:

| Column | Type | Content |
|---|---|---|
| `RecordId` | Int64 | The event record identifier |
| `TimeCreated` | datetime | `System/TimeCreated/@SystemTime`, falling back to the record header timestamp (UTC) |
| `Provider` | text | `System/Provider/@Name` |
| `EventId` | Int64 | `System/EventID` |
| `Level`, `LevelName` | Int64, text | Numeric level plus its name (Critical, Error, Warning, Informational, Verbose) |
| `Task`, `Opcode` | Int64 | `System/Task`, `System/Opcode` |
| `Keywords` | text | The keywords mask as hex text |
| `Channel`, `Computer` | text | Log channel and machine name |
| `ProcessId`, `ThreadId` | Int64 | From `System/Execution` |
| `UserId` | text | The SID from `System/Security/@UserID` |
| `EventData` | record | The event payload as a name to value record; expand it with `Table.ExpandRecordColumn` |
| `Xml` | text | The complete rendered event XML, for everything the columns do not cover |

`EventData` holds `EventData/Data` children keyed by their `Name` attribute
(`UserData` payloads are unwrapped the same way); values keep their native
types: numbers, text, datetimes, booleans, binary. Events from channels
with non-Event schemas keep their `Xml` and `RecordId`; the System columns
are null for them.

### Options

Second argument, optional record, all keys optional:

| Key | Default | Effect |
|---|---|---|
| `IncludeXml` | `true` | Set `false` to skip XML rendering and drop the `Xml` column; faster when only the extracted columns are needed |
| `Encoding` | 1252 | TextEncoding or codepage number for AnsiString values (rare; Unicode strings are unaffected) |
| `MaxRows` | all | Stop after N events |
| `Strict` | `false` | By default unparseable records are skipped (count in `Evtx.SkippedRecords` metadata) and chunks with bad signatures ignored, which is how a dirty log is recovered; `Strict = true` turns any malformation into an error |

The table carries `Evtx.Version`, `Evtx.IsDirty`, `Evtx.IsFull`,
`Evtx.NextRecordId`, `Evtx.ChunkCount`, `Evtx.DeclaredChunkCount` and
`Evtx.SkippedRecords` as metadata.

## Supported

- EVTX version 3.1 and 3.2 (Windows Vista through current Windows).
- The full binary XML token stream: elements, attributes, value text,
  character and entity references, CDATA sections, processing instructions.
- Templates: resident definitions, back-referenced definitions, the chunk
  template table, and definitions a corrupt table fails to link (parsed at
  their offset directly).
- Normal and conditional (optional) substitutions, including nested binary
  XML values (type 0x21) with their own templates and substitution arrays.
- All documented substitution value types: Unicode and ANSI strings, all
  integer widths signed and unsigned, float and double, boolean, binary,
  GUID, FILETIME, SYSTEMTIME, SID, hex32/hex64, size_t, Unicode string
  arrays.
- Dirty files: chunks are discovered by signature scan rather than the
  header's chunk count, so records the header does not yet acknowledge are
  recovered; within a chunk, record recovery walks until the first corrupt
  record.
- Records without a template instance (raw fragments).

## Limitations

- **Legacy `.evt` files** (Windows XP and Server 2003) are a different
  format entirely and produce a clear error saying so.
- **Checksums are not verified.** M has no CRC32 primitive worth running
  over every chunk; corruption surfaces as skipped records instead. The
  `Evtx.SkippedRecords` metadata says how many.
- **No slack-space carving.** Records that Windows has overwritten or that
  live past a chunk's free-space pointer are not recovered; this is a
  reader, not a forensic carver.
- **No message rendering.** The `%1`-style insertion strings live in
  provider message DLLs on the originating machine, not in the file; no
  parser can produce the friendly "An account was successfully logged on"
  sentence from the file alone. The structured fields it renders from are
  all in `EventData`.
- **Precision.** Integer values beyond 2^53 lose precision (M numbers are
  doubles). FILETIME timestamps are exempt: they are decoded exactly to the
  100 nanosecond tick.
- **Memory.** The whole file is buffered; peak memory is a multiple of file
  size. Windows caps `.evtx` files at 20 MB by default and most exports are
  smaller; multi-gigabyte forwarded-events archives are not this reader's
  use case.

## How it works

An EVTX file is a 4 KiB header followed by 64 KiB chunks. Each chunk is
self-contained: a header with record number ranges and a free-space
pointer, a 64-bucket hash table of name strings, a 32-bucket table of
template definitions, then event records. Every offset inside a chunk is
chunk-relative, so the reader slices each chunk out and parses it as its
own little world, prescanning both tables into lookup records first.

Event records hold a fragment of "binary XML": a token stream in which an
element carries an offset to its name (inline on first use,
back-referenced after), and most records are just a reference to a shared
template plus an array of typed substitution values. The reader parses
each template once per chunk into a placeholder tree, decodes each
record's value array, and substitutes values into placeholders. From the
resulting tree it renders the XML text and extracts the System columns
and the EventData record.

The format is documented by the libevtx project ("Windows XML Event Log
(EVTX)" format specification), with python-evtx as a reference
implementation; both were used to pin down the layouts.

## Testing

Fixtures in [`test/`](test/) are small, synthetic, and generated from
scratch by [`test/make_fixtures.py`](test/make_fixtures.py), including
correct CRC32 checksums, hash-bucket chains and template tables; no real
machine's logs are involved. [`test/expected.md`](test/expected.md)
describes what each fixture proves. The parse logic is mirrored in
[`test/mirror.py`](test/mirror.py) and validated by
[`test/check_mirror.py`](test/check_mirror.py), which walks every record
of every fixture through both the mirror and python-evtx (an independent
parser) into the same canonical tree and compares them value by value,
then checks the rendered XML is well-formed and pins the extracted
columns with golden assertions.
