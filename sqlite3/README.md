# SQLite 3

Read SQLite database files in pure Power Query M. No ODBC driver, no ADO.NET provider, no Python/R script host, no custom connector, no admin rights.

The function parses the [SQLite file format](https://www.sqlite.org/fileformat2.html) directly: file header, table b-trees, varints, record serial types, and overflow-page chains. Because it consumes plain bytes, it works anywhere Power Query runs.

## Why SQLite specifically

Power BI has no native SQLite connector. The standard answer is the SQLite ODBC driver, which requires a machine-level (HKLM) installation many corporate users can't perform. The mashup engine ships no SQLite ADO.NET provider either (its internal SQLite use is native-interop only), and custom connectors cannot bundle binaries. The remaining sanctioned escape hatch, the Python/R script host, requires a configured interpreter and blocks some Service refresh scenarios.

See the [root README](../README.md) for the wider motivation and the design rules every reader here follows.

## Usage

Paste the contents of [`SQLiteReader.pq`](SQLiteReader.pq) into a blank query and name the query `SQLite`. Power Query treats a query whose expression is a function as an invocable function.

```m
let
    db = SQLite(File.Contents("C:\data\example.db"))
in
    db
```

This returns a navigation table with one row per user table:

| Name | RootPage | SQL | Data |
|---|---|---|---|
| `orders` | 5 | `CREATE TABLE orders (...)` | *Table* |

Drill into a single table:

```m
let
    db  = SQLite(File.Contents("C:\data\example.db")),
    tbl = db{[Name = "orders"]}[Data]
in
    tbl
```

Any binary source works:

```m
// Hosted file: refreshes in the Service with no gateway
SQLite(Web.Contents("https://example.com/files/example.db"))

// SharePoint / OneDrive
SQLite(SharePoint.Files("https://tenant.sharepoint.com/sites/x")
       {[Name = "example.db"]}[Content])

// Folder source
SQLite(Folder.Files("C:\data"){[Name = "example.db"]}[Content])
```

## What is supported

- Ordinary rowid tables, including multi-level (interior + leaf) b-trees
- All record serial types: NULL, 1/2/3/4/6/8-byte signed integers, IEEE-754 doubles, constants 0/1, BLOBs, text
- Overflow pages (long text/BLOB values spanning pages), reassembled per the spec's inline-threshold math
- `INTEGER PRIMARY KEY` rowid aliasing: id columns are populated from the rowid instead of reading as null
- Short records from `ALTER TABLE ADD COLUMN` (padded with nulls)
- UTF-8, UTF-16LE, and UTF-16BE database encodings
- Non-default page sizes and reserved bytes per page
- Column names parsed from the stored `CREATE TABLE` DDL (quote-, bracket-, and nesting-aware), with a positional fallback if parsing fails

## Limitations

| Limitation | Detail |
|---|---|
| **WAL** | Only the main database file is read. Committed transactions still sitting in the `-wal` file are **not visible** until checkpointed. The nav table carries `SQLite.WalMode` metadata (`Value.Metadata`) so you can detect WAL databases. |
| **No locking** | The file is read without SQLite's locking protocol. Reading a database that is being written concurrently can yield a torn snapshot. Prefer reading a copy, a quiet-period snapshot, or a synced replica. |
| **No SQL** | You get whole-table scans; filtering and joining happen in M afterwards. There is no predicate pushdown. |
| **`WITHOUT ROWID` tables** | Stored as index b-trees; not implemented (such tables surface an error in their `Data` cell). |
| **Virtual tables** | No b-tree storage; surfaced as an error in their `Data` cell. |
| **Integer precision** | M numbers are IEEE doubles; integers beyond 2^53 lose precision. |
| **Performance** | Fine for small-to-medium databases. Whole-file buffering plus full scans means very large files will be slow; consider exporting hot tables to Parquet/CSV instead at that scale. |

## Reading a live, frequently-written database

If your `.db` is under constant write load (the scenario that motivated this reader):

1. **Copy first, read the copy.** Copy `your.db` (and, if present, `your.db-wal` + `your.db-shm`, though the WAL contents still won't be parsed) during a quiet window, then point `File.Contents` at the copy.
2. **Checkpoint before refresh.** Run `PRAGMA wal_checkpoint(TRUNCATE);` from any process that can open the DB, so the main file contains the latest committed state.
3. Or publish periodic snapshots to SharePoint/OneDrive/blob storage and read those. This also unlocks gateway-free Service refresh.

## How it works

1. Parse the 100-byte header: page size (offset 16), reserved space (20), text encoding (56), WAL flag (18).
2. Walk the table b-tree rooted at page 1 to decode `sqlite_master` (`type`, `name`, `tbl_name`, `rootpage`, `sql`).
3. For each user table, recursively walk its b-tree: interior pages (type 5) contribute child page pointers plus the rightmost pointer; leaf pages (type 13) contribute cells located via the 2-byte cell-pointer array.
4. Each leaf cell is `varint payload-length`, `varint rowid`, then the payload, which spills to a chain of overflow pages when it exceeds the usable-size threshold (`X = U − 35`, `M = ((U − 12) × 32 / 255) − 23`, `K = M + (P − M) mod (U − 4)`).
5. Payloads use the record format: a varint header of serial types followed by the value bytes; serial types map to NULL/int/float/blob/text.
6. Column names and the `INTEGER PRIMARY KEY` position come from lightweight parsing of the stored DDL.

Random access over the buffered binary is done with a `BinaryFormat.Record` skip/take trick, the same technique used by community pure-M ZIP readers.

## Compatibility

Power BI Desktop, Power BI dataflows, Excel Power Query, and anything else with a current M engine. No engine extensions or undocumented functions are used. Read-only by construction; the source file is never modified.

## Testing

Fixtures in [`test/`](test/) are small, synthetic databases generated by
[`test/make_fixtures.py`](test/make_fixtures.py) (Python standard library only,
so the writer is SQLite itself); [`test/expected.md`](test/expected.md)
describes what each one proves and the exact expected output. The decode logic
has been verified on every fixture: a byte-level mirror of the reader's exact
logic produces cell-identical results to the reference implementation reading
the same files.

To validate your own setup, compare against a known database before trusting
production numbers:

```
sqlite3 example.db "select count(*) from orders;"
```

Compare with `Table.RowCount` on the corresponding `Data` table. Good boundary cases: negative integers, NULLs in an `INTEGER PRIMARY KEY` column, and text values long enough to span overflow pages.
