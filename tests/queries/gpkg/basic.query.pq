let
    Doc = Gpkg.Database(PQDriverless.Fixture("gpkg.basic.gpkg")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
