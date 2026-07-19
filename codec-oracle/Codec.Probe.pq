// Codec.Probe - run the Parquet codec-oracle fixture matrix in one shot.
//
// Point it at the test/ folder holding the fixtures from make_fixtures.py:
//     Codec.Probe("C:\path\to\codec-oracle\test")
// Every *.parquet fixture is fed to Parquet.Document and the extracted payload
// is compared byte-for-byte against payload.csv from the same folder.
//
// Reading the matrix:
//   A_* rows: ordinary pyarrow-written files - does the host support the codec at all.
//   B_* rows: hand-rolled wrapper whose compressed page is an arbitrary external
//             codec stream - the oracle test.
//   B_uncompressed / B_gzip are wrapper sanity controls: if they fail, the wrapper
//   is malformed for this host and the other B failures say nothing about codecs.
//
// Record the host and build (Desktop / Service refresh / Excel / Dataflow Gen2)
// alongside the results; support may differ per host.
//
// SPDX-License-Identifier: Apache-2.0
let
    Codec.Probe = (fixtureFolder as text) as table =>
    let
        files = Folder.Files(fixtureFolder),
        expectedRows = Table.SelectRows(files, each [Name] = "payload.csv"),
        expected =
            if Table.RowCount(expectedRows) = 1 then expectedRows{0}[Content]
            else error Error.Record("DataFormat.Error",
                "payload.csv not found in " & fixtureFolder & "; keep the fixtures folder intact"),
        parquets = Table.SelectRows(files, each Text.EndsWith([Name], ".parquet")),
        probed = Table.AddColumn(parquets, "Result",
            each
                let
                    attempt = try Parquet.Document([Content]){0}[payload]
                in
                    if attempt[HasError] then
                        "ERROR: " & attempt[Error][Reason] & " - " & attempt[Error][Message]
                    else if attempt[Value] = expected then
                        "OK - decompressed to the expected payload"
                    else
                        "MISMATCH - parsed but returned "
                            & Text.From(Binary.Length(attempt[Value])) & " unexpected bytes",
            type text),
        report = Table.Sort(Table.SelectColumns(probed, {"Name", "Result"}), {{"Name", Order.Ascending}})
    in
        report
in
    Codec.Probe
