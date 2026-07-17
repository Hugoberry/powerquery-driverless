# powerquery-driverless

**Pure Power Query M readers for binary file formats. No drivers, no installs, no admin rights.**

> ⚠️ Early days. One reader so far (SQLite 3). This README is a placeholder and will grow as more land.

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
| Codec oracle (Snappy, Brotli, Zstandard, LZ4) | [`codec-oracle/`](codec-oracle/) | Working |

Power BI has no native SQLite connector. The usual answer is the SQLite ODBC driver and its machine-level install. This reader parses the [SQLite file format](https://www.sqlite.org/fileformat2.html) directly — header, table b-trees, varints, record serial types, overflow pages — so there's nothing to install.

```m
let
    Source = File.Contents("C:\data\chinook.db"),
    Db     = SQLite(Source),
    Tracks = Db{[Name = "tracks"]}[Data]
in
    Tracks
```

See [`sqlite3/README.md`](sqlite3/README.md) for setup, what's supported, and the limitations — particularly around WAL files and concurrent writes.

### The codec oracle

`Binary.Decompress` only implements GZip and Deflate, which would put every format that compresses its blocks with Snappy, Brotli, Zstandard or LZ4 out of reach. It turns out the engine ships those codecs anyway — `Parquet.Document` uses them — and [`codec-oracle/`](codec-oracle/) makes them callable from plain M by wrapping any compressed stream in a minimal in-memory Parquet file:

```m
Codec.Decompress(File.Contents("C:\data\block.snappy"), Compression.Snappy)
```

It behaves like the `Binary.Decompress` call that was never implemented, and it is the building block that lets readers here support formats whose internals use these codecs. See [`codec-oracle/README.md`](codec-oracle/README.md) for how it works and how to verify codec support on your host.

## Design rules

These are what make the paste-and-go promise hold:

- **Zero dependencies.** Standard library M only. No custom connector, no external assemblies, no ODBC.
- **One file, one function.** Each reader is a single self-contained `.pq`. No cross-file references — deliberately non-DRY, because the paste is the product.
- **Honest types.** Native types map to M types. Nothing stringified.
- **Read-only.** These readers only read. Nothing here writes to your files.

## Licence

[Apache License 2.0](LICENSE).
