// Data-only fold for the script benchmark: pyreadstat.read_sav / haven::read_sav
// return just the data matrix, so the fair driverless comparison decodes the
// same "Data" table (the full nav-doc fold also counts the Variables metadata
// table, +24 cells, which no library reproduces). See spss-bulk for that.
let
    Doc  = Spss.Document(PQDriverless.Fixture("perf.bulk.sav")),
    Data = Doc{[Name = "Data"]}[Data]
in
    List.Sum(List.Transform(Table.ToRows(Data), List.NonNullCount))
