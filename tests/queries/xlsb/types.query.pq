let
    Doc = Xlsb.Workbook(PQDriverless.Fixture("xlsb.types.xlsb")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
