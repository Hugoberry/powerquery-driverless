let
    Doc = AccessReader.Database(PQDriverless.Fixture("perf.bulk-ace.accdb")),
    Data = Doc{[Name = "data"]}[Data]
in
    List.Sum(List.Transform(Table.ToRows(Data), List.NonNullCount))
