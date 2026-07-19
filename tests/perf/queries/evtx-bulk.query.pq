List.Sum(List.Transform(Table.ToRows(Evtx.Document(PQDriverless.Fixture("perf.bulk.evtx"))), List.NonNullCount))
