// Integer-heavy full-decode fold: bulk-int.db forces signed serial types 1..6
// (the path e3350e5's hoisted BinaryFormat readers replaced), which the default
// bulk.db never exercises. Timing metric for the old-vs-new DecodeValue A/B.
// Output = intheavy-rows x 7 columns (id + c1..c6), all non-null.
let
    Doc  = Sqlite3.Database(PQDriverless.Fixture("perf.bulk-int.db")),
    Data = Doc{[Name = "data"]}[Data]
in
    List.Sum(List.Transform(Table.ToRows(Data), List.NonNullCount))
