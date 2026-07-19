let
    Doc = Xlsb.Workbook(PQDriverless.Fixture("xlsb.types.xlsb")),
    // types.xlsb contains a deliberate #N/A error cell. Error values cannot
    // round-trip through a .pqout literal (they serialize as comments), so
    // they are scrubbed to a text marker before the dump.
    Scrub = (t as table) as table =>
        Table.FromRows(
            List.Transform(Table.ToRows(t),
                (r) => List.Transform(r, (v) => try v otherwise "#ERROR")),
            Table.ColumnNames(t)),
    Out = Table.TransformColumns(Doc, {{"Data",
        each if Value.Is(_, type table) then Table.ToRecords(Scrub(_)) else _}})
in
    Out
