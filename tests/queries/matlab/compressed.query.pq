let
    Doc = Matlab.Document(PQDriverless.Fixture("matlab.compressed.mat")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
