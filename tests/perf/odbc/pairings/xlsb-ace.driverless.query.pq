// bulk-ace.xlsb is Excel-authored with a header row (the ACE ODBC driver
// always consumes row 1 as column names); Table.Skip(1) folds the same
// 10000 x 4 data cells the ODBC side returns.
let
    Doc = Xlsb.Workbook(PQDriverless.Fixture("perf.bulk-ace.xlsb")),
    Data = Doc{[Name = "Bulk"]}[Data]
in
    List.Sum(List.Transform(Table.ToRows(Table.Skip(Data, 1)), List.NonNullCount))
