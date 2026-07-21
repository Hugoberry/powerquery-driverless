// bulk-ace.xls is Excel-authored with a header row; Table.Skip(1) folds the
// same 8000 x 3 data cells the ODBC side returns.
let
    Doc = Xls.Workbook(PQDriverless.Fixture("perf.bulk-ace.xls")),
    Data = Doc{[Name = "Bulk"]}[Data]
in
    List.Sum(List.Transform(Table.ToRows(Table.Skip(Data, 1)), List.NonNullCount))
