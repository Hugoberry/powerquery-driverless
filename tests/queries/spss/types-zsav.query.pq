let
    Doc = Spss.Document(Extension.Contents("spss.types.zsav")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
