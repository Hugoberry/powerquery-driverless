let
    Doc = Sqlite3.Database(Extension.Contents("sqlite3.utf16le.db")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
