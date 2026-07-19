# EVTX fixtures, what each file proves

All fixtures are synthetic, generated from scratch by `make_fixtures.py` in
this directory (file and chunk headers, CRC32 checksums, string and template
hash tables, records). No real machine's logs are involved. Regenerate and
validate with:

```
python3 -m venv venv && venv/bin/pip install python-evtx
venv/bin/python make_fixtures.py
venv/bin/python check_mirror.py
```

`check_mirror.py` walks every record through both `mirror.py` (the parse
logic destined for `Evtx.Document.pq`) and python-evtx, an independent
reference parser, into the same canonical tree and compares them value by
value. python-evtx also verifies both CRC32 checksums of every chunk, which
the M reader deliberately skips.

To test a fixture through the reader:

```m
Evtx.Document(File.Contents("...\evtx\test\basic.evtx"))
```

## basic.evtx, 1 chunk, 6 records

A realistic Security-log shape: an `Event` template with `System`
(Provider, EventID 4624, Version, Level, Task, Opcode, Keywords hex64,
TimeCreated FILETIME, EventRecordID, Correlation, Execution, Channel,
Computer, Security SID) and `EventData` (TargetUserName string, LogonType
uint32). Record 1 carries the template resident; records 2 to 6
back-reference it, and all names are back-referenced after first use.

Proves: template instance parsing both resident and referenced, the name
and template hash tables, every System column extraction
(record 1: EventId 4624, Level 4 "Informational", Keywords
`0x8020000000000000`, Channel `Security`, Computer
`PQTEST-HOST.example.local`, ProcessId 716, ThreadId 820, UserId
`S-1-5-21-1111111111-2222222222-3333333333-1001`, EventData
`[TargetUserName = "user1", LogonType = 2]`), and conditional
substitutions: record 3 has a null Provider Guid (renders as an empty
attribute), record 4 adds an ActivityID, record 5 drops the Security SID
(UserId null).

## types.evtx, 1 chunk, 1 record

One `Data` element per substitution value type: wstring (with non-ASCII),
ANSI string, int8/uint8/int16/uint16/int32/uint32/int64/uint64, float32,
float64, boolean, binary, GUID, size_t, FILETIME (with a sub-second
100 ns component), SYSTEMTIME, SID, hex32, hex64, a Unicode string array,
a conditional null, literal text with every XML-escapable character, and
mixed content with a character reference and an `&amp;` entity reference.

Proves: every value decoder, XML escaping, hex zero-padding
(`0xdeadbeef`, `0x8000000000000001`), qwords at the 2^53 precision edge,
FILETIME decoded exactly (`2026-07-01T09:30:00.0000000Z` in the rendered
XML, and `2001-09-09 01:46:40.123456` as an EventData datetime), string
array splitting, and that EventData values keep their types.

## nested.evtx, 1 chunk, 2 records

A `Wrapper` template whose only substitution is of type 0x21: a complete
nested binary XML root with its own template (`Inner`) and its own
substitution array. Record 2 back-references both templates.

Proves: recursive root parsing inside substitution data, and that the
nested template participates in the chunk template table like any other.
Expected XML for both records:
`<Wrapper><Note>outer</Note><Payload><Inner><Value>42</Value><Label>inner label</Label></Inner></Payload></Wrapper>`.

## plain.evtx, 1 chunk, 2 records

Records whose binary XML is a raw fragment with no template instance:
literal elements, attributes with literal values, an empty element
(`<Empty/>`), nesting two levels deep, a processing instruction, and a
zero-entry substitution array. Record 2 reuses the same names
back-referenced.

Proves: the direct-fragment root path, and that non-Event roots yield null
System columns while keeping RecordId, TimeCreated (from the record
header) and Xml.

## multichunk.evtx, 3 chunks, 12 records

The basic template redefined in each chunk (chunk offsets are
chunk-relative, so nothing can be shared across chunks), record ids
running 1 to 12 across the file.

Proves: per-chunk name and template scoping, and record order across
chunks.

## dirty.evtx, 2 chunks, 6 records

The dirty flag is set and the file header declares only 1 chunk while 2
valid chunks exist, the state a log is in after a crash or a live copy.
python-evtx must be asked for inactive chunks to see the second one; the
reader's signature scan finds it unaided.

Proves: chunk discovery by signature scan rather than the header count
(`Evtx.ChunkCount` 2 against `Evtx.DeclaredChunkCount` 1), the
`Evtx.IsDirty` metadata, and that all 6 records are recovered.

## empty.evtx, header only

A 4096-byte file with zero chunks.

Proves: the empty table keeps the full column set, and
`Evtx.ChunkCount` is 0.

## Not covered by fixtures

- CDATA sections and multi-part attribute values (token flag 0x40) are
  implemented per the libevtx specification but cannot be cross-validated:
  python-evtx mis-parses CDATA and reads only one value part per
  attribute. Neither appears in ordinary Windows logs.
- Corrupt-record recovery inside a chunk (bad signature or size midway)
  is exercised only at the boundary the dirty fixture provides; the
  permissive skip path is otherwise covered by code review.
