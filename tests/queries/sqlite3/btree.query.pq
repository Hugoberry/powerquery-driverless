let
    Doc = Sqlite3.Database(PQDriverless.Fixture("sqlite3.btree.db")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.RowCount(_) else _}})
in
    Out
