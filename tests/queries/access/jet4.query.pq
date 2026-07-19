let
    Doc = AccessReader.Database(PQDriverless.Fixture("access.jet4.mdb")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
