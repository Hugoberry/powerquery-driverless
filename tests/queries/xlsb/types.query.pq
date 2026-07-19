let
    Doc = Xlsb.Workbook(PQDriverless.Fixture("xlsb.types.xlsb")),
    // types.xlsb contains deliberate error cells (#DIV/0!, #N/A). Error
    // values cannot round-trip through a .pqout literal (rows containing
    // them serialize as "null/*serialize failed*/" comments), so errors are
    // scrubbed to a text marker before the dump. Indexed access catches both
    // a row that is itself an error and error items inside a row.
    Scrub = (t as table) as table =>
        let n = Table.ColumnCount(t)
        in  Table.FromRows(
                List.Transform(Table.ToRows(t),
                    (r) => List.Transform({0 .. n - 1},
                        (i) => try r{i} otherwise "#ERROR")),
                Table.ColumnNames(t)),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(Scrub(_)) else _}})
in
    Out
