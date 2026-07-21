let
    Doc   = Mbtiles.Document(PQDriverless.Fixture("perf.bulk.mbtiles")),
    Tiles = Doc{[Name = "Tiles"]}[Data],
    // tile count + sum of decompressed tile_data byte lengths. The reader
    // auto-decompresses the gzip vector tiles, so Binary.Length sees the
    // inflated payload; the native side (sqlite3 + gzip) reproduces this.
    Cells = Table.RowCount(Tiles)
            + List.Sum(List.Transform(Tiles[tile_data], Binary.Length))
in
    Cells
