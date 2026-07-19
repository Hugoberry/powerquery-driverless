let
    Doc = Xls.Workbook(PQDriverless.Fixture("perf.bulk.xls")),
    Cells = List.Sum(List.Transform(
        List.Select(Table.Column(Doc, "Data"), (d) => Value.Is(d, type table)),
        (t) => List.Sum(List.Transform(Table.ToRows(t), List.NonNullCount))))
in
    Cells
