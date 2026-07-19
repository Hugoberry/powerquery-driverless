let
    Doc = Mbtiles.Document(PQDriverless.Fixture("mbtiles.vector.mbtiles")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.RowCount(_) else _}})
in
    Out
