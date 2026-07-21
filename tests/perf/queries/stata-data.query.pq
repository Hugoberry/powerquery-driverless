// Data-only fold for the script benchmark: pandas.read_stata / haven::read_dta
// return just the data matrix, so the fair driverless comparison decodes the
// same "Data" table (the full nav-doc fold also counts the Variables metadata
// table, +16 cells, which no library reproduces). See stata-bulk for that.
let
    Doc  = Stata.Document(PQDriverless.Fixture("perf.bulk.dta")),
    Data = Doc{[Name = "Data"]}[Data]
in
    List.Sum(List.Transform(Table.ToRows(Data), List.NonNullCount))
