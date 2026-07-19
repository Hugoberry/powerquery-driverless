let
    Doc = Access.Database(Extension.Contents("access.jet4.mdb")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
