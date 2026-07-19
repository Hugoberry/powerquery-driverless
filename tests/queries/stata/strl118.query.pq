let
    Doc = Stata.Document(PQDriverless.Fixture("stata.strl118.dta")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
