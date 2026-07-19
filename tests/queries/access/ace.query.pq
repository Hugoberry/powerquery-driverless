let
    Doc = AccessReader.Database(PQDriverless.Fixture("access.ace.accdb")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
