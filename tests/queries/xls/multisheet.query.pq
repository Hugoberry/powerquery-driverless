let
    Doc = Xls.Workbook(Extension.Contents("xls.multisheet.xls")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
