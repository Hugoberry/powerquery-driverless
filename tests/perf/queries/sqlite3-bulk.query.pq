let
    Doc  = Sqlite3.Database(PQDriverless.Fixture("perf.bulk.db")),
    Data = Doc{[Name = "data"]}[Data]
in
    List.Sum(List.Transform(Table.ToRows(Data), List.NonNullCount))
