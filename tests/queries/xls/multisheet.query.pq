let
    Doc = Xls.Workbook(PQDriverless.Fixture("xls.multisheet.xls")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
