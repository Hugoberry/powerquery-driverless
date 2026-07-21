// Structural (Tier 2) parity gate for evtx: the driverless reader flattens
// each event into its own ~16-column set while the pyevtx-rs library yields
// raw event XML, so per-cell counts cannot match. Both sides can agree on the
// event count, which this query supplies (the timed decode uses evtx-bulk).
Table.RowCount(Evtx.Document(PQDriverless.Fixture("perf.bulk.evtx")))
