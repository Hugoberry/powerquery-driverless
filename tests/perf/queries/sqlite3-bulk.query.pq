let
    Doc  = Sqlite3.Database(PQDriverless.Fixture("perf.bulk.db")),
    Data = Doc{[Name = "data"]}[Data]
in
    Table.RowCount(Data)
