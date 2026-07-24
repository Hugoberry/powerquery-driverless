# powerquery-driverless

**Pure Power Query M readers for binary file formats. No drivers, no installs, no admin rights.**

> ⚠️ Early days. Nine readers so far (SQLite 3, GeoPackage, MBTiles, Access, dBASE/FoxPro, EVTX, MATLAB `.mat`, legacy Excel .xls, Excel Binary .xlsb). This README is a placeholder and will grow as more land.

## Why this exists

In Power BI, the answer to "how do I read this file?" too often starts with "first, install this driver."

That answer assumes a machine you control. Plenty of people don't have one. The corporate desktop refuses machine-level installs. The gateway is someone else's server, and getting a driver onto it is a ticket, an approval, and a wait. The Power BI Service has no machine to install onto at all. So a perfectly ordinary file — one that arrived by email, or has been sitting on a SharePoint site for years — becomes unreadable, not for any technical reason, but because the only sanctioned path runs through an install that will never be approved.

The escape hatches don't help much either. The Python/R script host needs a configured interpreter and rules out some Service refresh scenarios. Custom connectors can't bundle binaries. Each workaround swaps one dependency for another.

These file formats are just bytes in a documented layout. Power Query can read bytes. So the dependency is optional — and this repo removes it.

Every reader here is plain M source. You paste it into a blank query and it works: Power BI Desktop, Excel, dataflows, the Service. Nothing to install, no bitness to match, no `provider is not registered`.

**On gateways, precisely:** the driver dependency goes away every time. The *gateway* only goes away when your file already lives somewhere the Service can reach — SharePoint, OneDrive, Blob, ADLS. If it's on an internal file share, you still need a gateway for network reach. But it's your existing standard gateway, with nothing special installed on it.

## What's here

| Component | Folder | Status |
|---|---|---|
| SQLite 3 reader (`.sqlite`, `.db`, `.db3`) | [`sqlite3/`](sqlite3/) | Working |
| GeoPackage reader (`.gpkg`) | [`gpkg/`](gpkg/) | Working |
| MBTiles reader (`.mbtiles`) | [`mbtiles/`](mbtiles/) | Working |
| Microsoft Access reader (`.mdb`, `.accdb`) | [`access/`](access/) | Working |
| dBASE / FoxPro reader (`.dbf` + `.fpt`/`.dbt`) | [`dbf/`](dbf/) | Working |
| Windows Event Log reader (`.evtx`) | [`evtx/`](evtx/) | Working |
| MATLAB MAT-file reader (`.mat`, v5-v7) | [`matlab/`](matlab/) | Working |
| Legacy Excel reader (`.xls`, Excel 97-2003) | [`xls/`](xls/) | Working |
| Excel Binary Workbook reader (`.xlsb`) | [`xlsb/`](xlsb/) | Working |
| Codec oracle (Snappy, Brotli, Zstandard, LZ4) | [`codec-oracle/`](codec-oracle/) | Working |
| CRC-32 (zlib, CRC-32C and friends) | [`crc32/`](crc32/) | Working |

Power BI has no native SQLite connector. The usual answer is the SQLite ODBC driver and its machine-level install. This reader parses the [SQLite file format](https://www.sqlite.org/fileformat2.html) directly — header, table b-trees, varints, record serial types, overflow pages — so there's nothing to install.

```m
let
    Source = File.Contents("C:\data\chinook.db"),
    Db     = Sqlite3.Database(Source),
    Tracks = Db{[Name = "tracks"]}[Data]
in
    Tracks
```

See [`sqlite3/README.md`](sqlite3/README.md) for setup, what's supported, and the limitations — particularly around WAL files and concurrent writes.

### Microsoft Access

Access is the format where the install pain is sharpest. A native connector exists, but it is a wrapper over the ACE OLEDB provider: bitness must match on the Desktop, 64-bit ACE must be installed on the gateway, Click-to-Run Office hides its ACE copy from the gateway entirely, and cloud hosts cannot install it at all. Hence `The 'Microsoft.ACE.OLEDB.12.0' provider is not registered`. This reader parses the Jet 4 / ACE page format directly, so none of that applies.

```m
let
    Source = File.Contents("C:\data\example.accdb"),
    Db     = Access.Database(Source),
    Orders = Db{[Name = "Orders"]}[Data]
in
    Orders
```

See [`access/README.md`](access/README.md) for what's supported and the limitations, in particular around encrypted databases (detected, not supported) and Access 97 files.

### dBASE / FoxPro

The applications built on FoxPro and dBASE never quite died; their `.dbf` files still land on shares, and the only sanctioned reader is the 32-bit Visual FoxPro ODBC/OLE DB driver from 2007. This reader parses the format directly: dBASE III through Visual FoxPro, memo sidecars (`.fpt`/`.dbt`), null flags, varchar, deleted-record flags, language-driver codepages.

```m
let
    Source = File.Contents("C:\data\customers.dbf"),
    Data   = Dbf.Table(Source, [Memo = File.Contents("C:\data\customers.fpt")])
in
    Data
```

See [`dbf/README.md`](dbf/README.md) for options, the type mapping, and limitations.

### Legacy Excel and Excel Binary

Power Query reads `.xls` and `.xlsb` through the Access Database Engine (ACE), which cannot be installed in cloud environments, so these files force a gateway in Power Query Online even when they already sit in SharePoint or Blob Storage. These readers parse BIFF8-in-CFB (`.xls`) and BIFF12-in-ZIP (`.xlsb`) directly. They are also more correct than the ACE path: ACE guesses column types from the first rows and nulls out mismatches, while these readers decode every cell from its record type. See [`xls/README.md`](xls/README.md) and [`xlsb/README.md`](xlsb/README.md).

### The codec oracle

`Binary.Decompress` only implements GZip and Deflate, which would put every format that compresses its blocks with Snappy, Brotli, Zstandard or LZ4 out of reach. It turns out the engine ships those codecs anyway — `Parquet.Document` uses them — and [`codec-oracle/`](codec-oracle/) makes them callable from plain M by wrapping any compressed stream in a minimal in-memory Parquet file:

```m
Codec.Decompress(File.Contents("C:\data\block.snappy"), Compression.Snappy)
```

It behaves like the `Binary.Decompress` call that was never implemented, and it is the building block that lets readers here support formats whose internals use these codecs. See [`codec-oracle/README.md`](codec-oracle/README.md) for how it works and how to verify codec support on your host.

### CRC-32

M has no hashing functions, so file-format checksums (gzip trailers, zip entries, PNG chunks, snappy blocks) normally go unverified. [`crc32/`](crc32/) is a table-driven `Crc32.Compute(binary, optional variant)` covering the zlib polynomial, CRC-32C (Castagnoli, with the snappy framing mask as an option) and the other common variants. See [`crc32/README.md`](crc32/README.md).

## Design rules

These are what make the paste-and-go promise hold:

- **Zero dependencies.** Standard library M only. No custom connector, no external assemblies, no ODBC.
- **One file, one function.** Each reader is a single self-contained `.pq`. No cross-file references — deliberately non-DRY, because the paste is the product. The one exception: readers for formats that *are* SQLite databases (GeoPackage, MBTiles) call `Sqlite3.Database` as a second pasted query instead of embedding the whole b-tree parser, so SQLite bugfixes land in one place.

## Performance — what to expect

Decoding in interpreted M is slower than a compiled driver. That is the price of
having no driver, and how much it costs depends almost entirely on file size:

- **Small and typical files** — the size most ad-hoc imports actually are — the
  gap is usually sub-second and often invisible. A native ODBC driver spends
  roughly a second just standing up its connection, which swamps the decode
  either way. Against the ACE Excel / Access / dBASE drivers the pure-M readers
  land between parity and a few times slower, and the dBASE reader is a dead heat.
- **Large files** — native decoders pull ahead as per-row cost takes over:
  about **2–15x** against ODBC drivers (SQLite, ACE), and more against mature
  compiled libraries — up to a couple of hundred× for the Rust- and GDAL-backed
  formats (EVTX, GeoPackage) that have no ODBC driver to compare against at all.

So choose by size and setting, not a single headline number. For a one-off or
modest file the driverless reader is the easy call — nothing to install, and it
runs in the Service where a driver cannot. For repeated decode of large files on
a machine that *can* carry the toolchain, a native driver or library is the
faster tool. Full method, per-format numbers, and both scales are in
[`tests/perf/REPORT.md`](tests/perf/REPORT.md).

## Licence

[Apache License 2.0](LICENSE).
