List.Sum(List.Transform(Table.ToRows(Avro.Document(PQDriverless.Fixture("perf.bulk.avro"))), List.NonNullCount))
