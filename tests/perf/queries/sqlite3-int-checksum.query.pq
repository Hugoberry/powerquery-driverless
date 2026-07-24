// Value-sensitive checksum over the integer-heavy fixture: sums (value mod 1e6)
// over every signed integer cell (c1..c6). The modulus keeps the running total
// exactly representable in M's double arithmetic (individual cells are all
// < 2^53, so their residues and this sum are exact), while still forcing a full
// correct decode of each cell. Compared old-code vs new-code (must agree, and
// both equal the value derived from a correct decode: 23283749964 for the
// 300k-row fixture). Note M's Number.Mod follows the DIVIDEND sign, so the
// sign-extended negative columns c2/c4 contribute negative residues — the
// expected value is computed with that same convention, not Python's % .
let
    Doc  = Sqlite3.Database(PQDriverless.Fixture("perf.bulk-int.db")),
    Data = Doc{[Name = "data"]}[Data],
    cols = {"c1", "c2", "c3", "c4", "c5", "c6"}
in
    List.Sum(List.Transform(cols,
        (c) => List.Sum(List.Transform(Table.Column(Data, c), each Number.Mod(_, 1000000)))))
