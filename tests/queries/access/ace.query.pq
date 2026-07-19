let
    Doc = Access.Database(Extension.Contents("access.ace.accdb")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
