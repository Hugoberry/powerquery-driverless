let
    Doc = Xlsb.Workbook(Extension.Contents("xlsb.types.xlsb")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
