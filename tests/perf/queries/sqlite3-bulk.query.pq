let
    Doc  = Sqlite3.Database(Extension.Contents("perf.bulk.db")),
    Data = Doc{[Name = "data"]}[Data]
in
    Table.RowCount(Data)
