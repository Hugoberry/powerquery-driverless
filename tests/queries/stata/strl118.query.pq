let
    Doc = Stata.Document(Extension.Contents("stata.strl118.dta")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
