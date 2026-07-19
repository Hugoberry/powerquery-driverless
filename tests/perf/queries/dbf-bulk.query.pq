List.Sum(List.Transform(Table.ToRows(Dbf.Table(PQDriverless.Fixture("perf.bulk.dbf"))), List.NonNullCount))
