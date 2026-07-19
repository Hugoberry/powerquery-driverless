let
    Doc = Matlab.Document(Extension.Contents("matlab.compressed.mat")),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(_) else _}})
in
    Out
