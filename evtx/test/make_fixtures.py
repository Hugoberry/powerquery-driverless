# SPDX-License-Identifier: Apache-2.0
#
# Synthetic EVTX fixture writer for Evtx.Document.pq.
#
# Every fixture is generated from scratch (no Windows machine, no customer
# files): file header, chunks, chunk string/template tables with correct
# hash-bucket chains, CRC32 checksums, resident and back-referenced template
# definitions, inline and back-referenced name strings. The files are
# validated against python-evtx (the independent reference parser) by
# check_mirror.py.
#
#   python3 -m venv venv && venv/bin/pip install python-evtx
#   venv/bin/python make_fixtures.py

import struct
import uuid
import datetime
from binascii import crc32
from pathlib import Path

HERE = Path(__file__).parent

EPOCH_DELTA = 11644473600  # seconds between 1601-01-01 and 1970-01-01


def filetime(dt):
    """datetime (assumed UTC) -> FILETIME qword (100ns since 1601)."""
    ts = dt.replace(tzinfo=datetime.timezone.utc).timestamp()
    return int(round((ts + EPOCH_DELTA) * 10_000_000))


def name_hash(name):
    h = 0
    for c in name:
        h = (h * 65599 + ord(c)) & 0xFFFF
    return h


def utf16(s):
    return s.encode("utf-16-le")


def make_sid(revision, authority, subauthorities):
    out = bytes([revision, len(subauthorities)])
    out += authority.to_bytes(6, "big")
    for sa in subauthorities:
        out += struct.pack("<I", sa)
    return out


# ---------------------------------------------------------------------------
# value encoding for substitution data (declared-size encoding: no prefixes)
# ---------------------------------------------------------------------------

def encode_value(vtype, value):
    if vtype == 0x00:
        return b""
    if vtype == 0x01:
        return utf16(value)
    if vtype == 0x02:
        return value.encode("cp1252")
    if vtype == 0x03:
        return struct.pack("<b", value)
    if vtype == 0x04:
        return struct.pack("<B", value)
    if vtype == 0x05:
        return struct.pack("<h", value)
    if vtype == 0x06:
        return struct.pack("<H", value)
    if vtype == 0x07:
        return struct.pack("<i", value)
    if vtype == 0x08:
        return struct.pack("<I", value)
    if vtype == 0x09:
        return struct.pack("<q", value)
    if vtype == 0x0A:
        return struct.pack("<Q", value)
    if vtype == 0x0B:
        return struct.pack("<f", value)
    if vtype == 0x0C:
        return struct.pack("<d", value)
    if vtype == 0x0D:
        return struct.pack("<i", 1 if value else 0)
    if vtype == 0x0E:
        return bytes(value)
    if vtype == 0x0F:
        return value.bytes_le  # uuid.UUID
    if vtype == 0x10:
        return struct.pack("<Q", value)  # size_t, 8-byte flavour
    if vtype == 0x11:
        return struct.pack("<Q", value)  # FILETIME qword
    if vtype == 0x12:
        return struct.pack("<8H", *value)  # SYSTEMTIME tuple
    if vtype == 0x13:
        return bytes(value)  # SID bytes
    if vtype == 0x14:
        return struct.pack("<I", value)
    if vtype == 0x15:
        return struct.pack("<Q", value)
    if vtype == 0x21:
        return bytes(value)  # nested binxml root, pre-built
    if vtype == 0x81:
        return b"".join(utf16(s) + b"\x00\x00" for s in value)
    raise ValueError("unsupported value type 0x%02x" % vtype)


# ---------------------------------------------------------------------------
# element tree model
#   El(name, attrs=[(name, item)], content=[item...], empty=False)
#   item: ("text", s) | ("sub", index, vtype, conditional) | ("charref", n)
#         | ("entityref", name) | ("cdata", s) | ("pi", target, data) | El
# ---------------------------------------------------------------------------

class El:
    def __init__(self, name, attrs=None, content=None):
        self.name = name
        self.attrs = attrs or []
        self.content = content if content is not None else []


class ChunkBuilder:
    def __init__(self):
        self.buf = bytearray(0x10000)
        self.pos = 0x200
        self.names = {}                # name -> chunk-relative offset
        self.string_buckets = [0] * 64
        self.templates = {}            # guid -> definition offset
        self.template_buckets = [0] * 32
        self.first_id = None
        self.last_id = None
        self.last_record_offset = 0

    # -- primitives ---------------------------------------------------------

    def w8(self, v):
        self.buf[self.pos] = v & 0xFF
        self.pos += 1

    def w16(self, v):
        struct.pack_into("<H", self.buf, self.pos, v)
        self.pos += 2

    def w32(self, v):
        struct.pack_into("<I", self.buf, self.pos, v)
        self.pos += 4

    def w64(self, v):
        struct.pack_into("<Q", self.buf, self.pos, v)
        self.pos += 8

    def wbytes(self, b):
        self.buf[self.pos : self.pos + len(b)] = b
        self.pos += len(b)

    def patch32(self, off, v):
        struct.pack_into("<I", self.buf, off, v)

    # -- name strings -------------------------------------------------------

    def emit_name(self, name):
        """Return the chunk-relative offset of the name string, writing it
        inline at the current position if it is new to this chunk."""
        if name in self.names:
            return self.names[name]
        off = self.pos
        h = name_hash(name)
        bucket = h % 64
        self.w32(self.string_buckets[bucket])  # next in bucket chain
        self.w16(h)
        self.w16(len(name))
        self.wbytes(utf16(name))
        self.w16(0)                            # terminator
        self.string_buckets[bucket] = off
        self.names[name] = off
        return off

    # -- binxml emit --------------------------------------------------------

    def emit_item(self, item):
        if isinstance(item, El):
            self.emit_element(item)
            return
        kind = item[0]
        if kind == "text":
            s = item[1]
            self.w8(0x05)
            self.w8(0x01)
            self.w16(len(s))
            self.wbytes(utf16(s))
        elif kind == "sub":
            _, index, vtype, conditional = item
            self.w8(0x0E if conditional else 0x0D)
            self.w16(index)
            self.w8(vtype)
        elif kind == "charref":
            self.w8(0x08)
            self.w16(item[1])
        elif kind == "entityref":
            self.w8(0x09)
            fixup = self.pos
            self.w32(0)
            self.patch32(fixup, self.emit_name_forward(item[1]))
        elif kind == "cdata":
            s = item[1]
            self.w8(0x07)
            self.w16(len(s))
            self.wbytes(utf16(s))
        elif kind == "pi":
            _, target, data = item
            self.w8(0x0A)
            fixup = self.pos
            self.w32(0)
            self.patch32(fixup, self.emit_name_forward(target))
            self.w8(0x0B)
            self.w16(len(data))
            self.wbytes(utf16(data))
        else:
            raise ValueError(kind)

    def emit_name_forward(self, name):
        """Emit a name whose 4-byte offset field has already been written
        just before the current position (the inline-name convention)."""
        return self.emit_name(name)

    def emit_element(self, el):
        start = self.pos
        has_attrs = bool(el.attrs)
        self.w8(0x41 if has_attrs else 0x01)
        self.w16(0xFFFF)                      # dependency identifier: not set
        size_fixup = self.pos
        self.w32(0)                           # data size, patched below
        name_fixup = self.pos
        self.w32(0)
        self.patch32(name_fixup, self.emit_name(el.name))
        if has_attrs:
            attr_size_fixup = self.pos
            self.w32(0)
            attrs_start = self.pos
            for i, (aname, aval) in enumerate(el.attrs):
                last = i == len(el.attrs) - 1
                self.w8(0x06 if last else 0x46)
                afixup = self.pos
                self.w32(0)
                self.patch32(afixup, self.emit_name(aname))
                self.emit_item(aval)
            self.patch32(attr_size_fixup, self.pos - attrs_start)
        if el.content:
            self.w8(0x02)                     # close start element
            for item in el.content:
                self.emit_item(item)
            self.w8(0x04)                     # end element
        else:
            self.w8(0x03)                     # close empty element
        # data size: everything after the size field, end token included
        self.patch32(size_fixup, self.pos - (size_fixup + 4))

    def emit_template_instance(self, guid, tree):
        """Fragment header + template instance token; resident definition on
        first use in the chunk, back-reference afterwards."""
        self.wbytes(b"\x0F\x01\x01\x00")      # fragment header
        self.w8(0x0C)
        self.w8(0x01)
        template_id = struct.unpack("<I", guid.bytes_le[:4])[0]
        self.w32(template_id)
        offset_fixup = self.pos
        self.w32(0)
        if guid in self.templates:
            self.patch32(offset_fixup, self.templates[guid])
            return
        def_off = self.pos
        self.patch32(offset_fixup, def_off)
        bucket = template_id % 32
        self.w32(self.template_buckets[bucket])  # next definition in chain
        self.wbytes(guid.bytes_le)
        data_size_fixup = self.pos
        self.w32(0)
        data_start = self.pos
        self.wbytes(b"\x0F\x01\x01\x00")      # fragment header
        self.emit_element(tree)
        self.w8(0x00)                         # end of stream
        self.patch32(data_size_fixup, self.pos - data_start)
        self.template_buckets[bucket] = def_off
        self.templates[guid] = def_off

    def emit_substitution_data(self, subs):
        """subs: list of (vtype, value); value None means NULL entry."""
        encoded = []
        for vtype, value in subs:
            if value is None:
                encoded.append((0x00, b""))
            else:
                encoded.append((vtype, encode_value(vtype, value)))
        self.w32(len(encoded))
        for vtype, data in encoded:
            self.w16(len(data))
            self.w8(vtype)
            self.w8(0)
        for _, data in encoded:
            self.wbytes(data)

    # -- records ------------------------------------------------------------

    def add_record(self, record_id, written, body_writer):
        """body_writer(self) emits the record's binxml at the current pos."""
        start = self.pos
        self.w32(0x00002A2A)
        size_fixup = self.pos
        self.w32(0)
        self.w64(record_id)
        self.w64(filetime(written))
        body_writer(self)
        self.w32(0)                           # trailing size copy, patched
        size = self.pos - start
        self.patch32(size_fixup, size)
        self.patch32(self.pos - 4, size)
        if self.first_id is None:
            self.first_id = record_id
        self.last_id = record_id
        self.last_record_offset = start

    def template_record(self, guid, tree, subs):
        def writer(c):
            c.emit_template_instance(guid, tree)
            c.emit_substitution_data(subs)
        return writer

    def plain_record(self, trees):
        def writer(c):
            c.wbytes(b"\x0F\x01\x01\x00")
            for tree in trees:
                c.emit_element(tree)
            c.w8(0x00)
            c.w32(0)                          # zero substitutions
        return writer

    # -- finalize -----------------------------------------------------------

    def finalize(self):
        struct.pack_into("<8s", self.buf, 0, b"ElfChnk\x00")
        struct.pack_into("<QQQQ", self.buf, 8,
                         self.first_id or 0, self.last_id or 0,
                         self.first_id or 0, self.last_id or 0)
        struct.pack_into("<IIII", self.buf, 0x28,
                         0x80, self.last_record_offset, self.pos, 0)
        for i, off in enumerate(self.string_buckets):
            struct.pack_into("<I", self.buf, 0x80 + 4 * i, off)
        for i, off in enumerate(self.template_buckets):
            struct.pack_into("<I", self.buf, 0x180 + 4 * i, off)
        data_crc = crc32(self.buf[0x200 : self.pos]) & 0xFFFFFFFF
        struct.pack_into("<I", self.buf, 0x34, data_crc)
        header_crc = crc32(bytes(self.buf[0:0x78]) + bytes(self.buf[0x80:0x200])) & 0xFFFFFFFF
        struct.pack_into("<I", self.buf, 0x7C, header_crc)
        return bytes(self.buf)


def build_file(chunks, next_record_id, flags=0, declared_chunks=None):
    header = bytearray(0x1000)
    struct.pack_into("<8s", header, 0, b"ElfFile\x00")
    struct.pack_into("<QQQ", header, 8,
                     0,                        # oldest chunk
                     max(len(chunks) - 1, 0),  # current chunk number
                     next_record_id)
    n = len(chunks) if declared_chunks is None else declared_chunks
    struct.pack_into("<IHHHH", header, 0x20, 0x80, 1, 3, 0x1000, n)
    struct.pack_into("<I", header, 0x78, flags)
    struct.pack_into("<I", header, 0x7C, crc32(header[0:0x78]) & 0xFFFFFFFF)
    return bytes(header) + b"".join(chunks)


# ---------------------------------------------------------------------------
# shared template shapes
# ---------------------------------------------------------------------------

EVENT_GUID = uuid.UUID("11111111-2222-3333-4444-555555555555")
NESTED_GUID = uuid.UUID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
TYPES_GUID = uuid.UUID("99999999-8888-7777-6666-555555555555")

PROVIDER_GUID = uuid.UUID("5770385f-c22a-43e0-bf4c-06f5698ffbd9")
ACTIVITY_GUID = uuid.UUID("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")
USER_SID = make_sid(1, 5, [21, 1111111111, 2222222222, 3333333333, 1001])

BASE_TIME = datetime.datetime(2026, 7, 1, 9, 30, 0)


def event_tree():
    """The shape Windows itself uses: System block + EventData."""
    return El("Event",
              attrs=[("xmlns", ("text", "http://schemas.microsoft.com/win/2004/08/events/event"))],
              content=[
        El("System", content=[
            El("Provider", attrs=[("Name", ("sub", 0, 0x01, False)),
                                  ("Guid", ("sub", 1, 0x0F, True))]),
            El("EventID", content=[("sub", 2, 0x06, False)]),
            El("Version", content=[("sub", 3, 0x04, False)]),
            El("Level", content=[("sub", 4, 0x04, False)]),
            El("Task", content=[("sub", 5, 0x06, False)]),
            El("Opcode", content=[("sub", 6, 0x04, False)]),
            El("Keywords", content=[("sub", 7, 0x15, False)]),
            El("TimeCreated", attrs=[("SystemTime", ("sub", 8, 0x11, False))]),
            El("EventRecordID", content=[("sub", 9, 0x0A, False)]),
            El("Correlation", attrs=[("ActivityID", ("sub", 10, 0x0F, True))]),
            El("Execution", attrs=[("ProcessID", ("sub", 11, 0x08, False)),
                                   ("ThreadID", ("sub", 12, 0x08, False))]),
            El("Channel", content=[("sub", 13, 0x01, False)]),
            El("Computer", content=[("sub", 14, 0x01, False)]),
            El("Security", attrs=[("UserID", ("sub", 15, 0x13, True))]),
        ]),
        El("EventData", content=[
            El("Data", attrs=[("Name", ("text", "TargetUserName"))],
               content=[("sub", 16, 0x01, False)]),
            El("Data", attrs=[("Name", ("text", "LogonType"))],
               content=[("sub", 17, 0x08, False)]),
        ]),
    ])


def event_subs(record_id, when, user, logon_type,
               with_guid=True, with_activity=False, with_sid=True):
    return [
        (0x01, "PQ-Driverless-Test"),
        (0x0F, PROVIDER_GUID if with_guid else None),
        (0x06, 4624),
        (0x04, 2),
        (0x04, 4 if logon_type != 10 else 3),
        (0x06, 12544),
        (0x04, 0),
        (0x15, 0x8020000000000000),
        (0x11, filetime(when)),
        (0x0A, record_id),
        (0x0F, ACTIVITY_GUID if with_activity else None),
        (0x08, 716),
        (0x08, 820),
        (0x01, "Security"),
        (0x01, "PQTEST-HOST.example.local"),
        (0x13, USER_SID if with_sid else None),
        (0x01, user),
        (0x08, logon_type),
    ]


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

def fx_basic():
    c = ChunkBuilder()
    for i in range(6):
        rid = i + 1
        when = BASE_TIME + datetime.timedelta(minutes=i)
        c.add_record(rid, when, c.template_record(
            EVENT_GUID, event_tree(),
            event_subs(rid, when, "user%d" % rid, 2 if i % 2 == 0 else 10,
                       with_guid=(i != 2),
                       with_activity=(i == 3),
                       with_sid=(i != 4))))
    return build_file([c.finalize()], next_record_id=7)


def types_tree():
    return El("Event", content=[
        El("System", content=[
            El("Provider", attrs=[("Name", ("text", "PQ-Types"))]),
            El("EventID", content=[("text", "1000")]),
            El("TimeCreated", attrs=[("SystemTime", ("sub", 0, 0x11, False))]),
            El("EventRecordID", content=[("sub", 1, 0x0A, False)]),
            El("Channel", content=[("text", "PQ-Test/Types")]),
            El("Computer", content=[("text", "PQTEST-HOST")]),
        ]),
        El("EventData", content=[
            El("Data", attrs=[("Name", ("text", "wstr"))], content=[("sub", 2, 0x01, False)]),
            El("Data", attrs=[("Name", ("text", "astr"))], content=[("sub", 3, 0x02, False)]),
            El("Data", attrs=[("Name", ("text", "i8"))], content=[("sub", 4, 0x03, False)]),
            El("Data", attrs=[("Name", ("text", "u8"))], content=[("sub", 5, 0x04, False)]),
            El("Data", attrs=[("Name", ("text", "i16"))], content=[("sub", 6, 0x05, False)]),
            El("Data", attrs=[("Name", ("text", "u16"))], content=[("sub", 7, 0x06, False)]),
            El("Data", attrs=[("Name", ("text", "i32"))], content=[("sub", 8, 0x07, False)]),
            El("Data", attrs=[("Name", ("text", "u32"))], content=[("sub", 9, 0x08, False)]),
            El("Data", attrs=[("Name", ("text", "i64"))], content=[("sub", 10, 0x09, False)]),
            El("Data", attrs=[("Name", ("text", "u64"))], content=[("sub", 11, 0x0A, False)]),
            El("Data", attrs=[("Name", ("text", "f32"))], content=[("sub", 12, 0x0B, False)]),
            El("Data", attrs=[("Name", ("text", "f64"))], content=[("sub", 13, 0x0C, False)]),
            El("Data", attrs=[("Name", ("text", "flag"))], content=[("sub", 14, 0x0D, False)]),
            El("Data", attrs=[("Name", ("text", "blob"))], content=[("sub", 15, 0x0E, False)]),
            El("Data", attrs=[("Name", ("text", "guid"))], content=[("sub", 16, 0x0F, False)]),
            El("Data", attrs=[("Name", ("text", "size"))], content=[("sub", 17, 0x10, False)]),
            El("Data", attrs=[("Name", ("text", "ft"))], content=[("sub", 18, 0x11, False)]),
            El("Data", attrs=[("Name", ("text", "st"))], content=[("sub", 19, 0x12, False)]),
            El("Data", attrs=[("Name", ("text", "sid"))], content=[("sub", 20, 0x13, False)]),
            El("Data", attrs=[("Name", ("text", "h32"))], content=[("sub", 21, 0x14, False)]),
            El("Data", attrs=[("Name", ("text", "h64"))], content=[("sub", 22, 0x15, False)]),
            El("Data", attrs=[("Name", ("text", "sarr"))], content=[("sub", 23, 0x81, False)]),
            El("Data", attrs=[("Name", ("text", "gone"))], content=[("sub", 24, 0x01, True)]),
            El("Data", attrs=[("Name", ("text", "esc"))],
               content=[("text", 'a<b&c>"d\'  é✓')]),
            El("Data", attrs=[("Name", ("text", "refs"))],
               content=[("text", "x"), ("charref", 0x266B), ("entityref", "amp"), ("text", "y")]),
        ]),
    ])


def fx_types():
    c = ChunkBuilder()
    when = BASE_TIME
    subs = [
        (0x11, filetime(when)),
        (0x0A, 1),
        (0x01, "héllo wörld ✓"),
        (0x02, "ansi text"),
        (0x03, -128),
        (0x04, 255),
        (0x05, -32000),
        (0x06, 65535),
        (0x07, -2000000000),
        (0x08, 4000000000),
        (0x09, -9007199254740991),
        (0x0A, 9007199254740991),
        (0x0B, 1.5),
        (0x0C, -2.75e10),
        (0x0D, True),
        (0x0E, bytes(range(16))),
        (0x0F, PROVIDER_GUID),
        (0x10, 1048576),
        (0x11, filetime(datetime.datetime(2001, 9, 9, 1, 46, 40)) + 1234567),
        (0x12, (2026, 7, 3, 18, 23, 59, 58, 999)),
        (0x13, USER_SID),
        (0x14, 0xDEADBEEF),
        (0x15, 0x8000000000000001),
        (0x81, ["alpha", "beta", "gamma"]),
        (0x01, None),
    ]
    c.add_record(1, when, c.template_record(TYPES_GUID, types_tree(), subs))
    return build_file([c.finalize()], next_record_id=2)


NESTED_GUID_INNER = uuid.UUID("12121212-3434-5656-7878-909090909090")


def fx_nested():
    c = ChunkBuilder()

    # A substitution of type 0x21 holds a complete nested binxml root
    # (fragment + template instance + its own substitution data). It embeds
    # chunk-relative name/template offsets, so it must be built in place: the
    # record body is written manually rather than via encode_value.
    def writer(chunk):
        chunk.emit_template_instance(
            NESTED_GUID,
            El("Wrapper", content=[
                El("Note", content=[("text", "outer")]),
                El("Payload", content=[("sub", 0, 0x21, False)]),
            ]))

        inner_tree = El("Inner", content=[
            El("Value", content=[("sub", 0, 0x06, False)]),
            El("Label", content=[("sub", 1, 0x01, False)]),
        ])

        # declaration: one substitution of type 0x21 whose size is patched
        chunk.w32(1)
        decl_fixup = chunk.pos
        chunk.w16(0)
        chunk.w8(0x21)
        chunk.w8(0)
        nested_start = chunk.pos
        chunk.emit_template_instance(NESTED_GUID_INNER, inner_tree)
        chunk.emit_substitution_data([(0x06, 42), (0x01, "inner label")])
        struct.pack_into("<H", chunk.buf, decl_fixup, chunk.pos - nested_start)

    c.add_record(1, BASE_TIME, writer)
    # second record back-references both templates
    c.add_record(2, BASE_TIME + datetime.timedelta(seconds=30), writer)
    return build_file([c.finalize()], next_record_id=3)


def fx_plain():
    c = ChunkBuilder()
    tree1 = El("Log", attrs=[("kind", ("text", "plain"))], content=[
        El("Message", content=[("text", "no template here")]),
        El("Empty"),
        El("Nested", content=[
            El("Deep", attrs=[("depth", ("text", "2"))], content=[("text", "leaf")]),
        ]),
        El("Extra", content=[("pi", "pq-test", "keep me")]),
    ])
    tree2 = El("Log", attrs=[("kind", ("text", "second"))], content=[
        El("Message", content=[("text", "same names, back-referenced")]),
    ])
    c.add_record(1, BASE_TIME, c.plain_record([tree1]))
    c.add_record(2, BASE_TIME + datetime.timedelta(seconds=5), c.plain_record([tree2]))
    return build_file([c.finalize()], next_record_id=3)


def fx_multichunk():
    chunks = []
    rid = 1
    for ci in range(3):
        c = ChunkBuilder()
        for i in range(4):
            when = BASE_TIME + datetime.timedelta(hours=ci, minutes=i)
            c.add_record(rid, when, c.template_record(
                EVENT_GUID, event_tree(),
                event_subs(rid, when, "chunk%d-user%d" % (ci, i), 2)))
            rid += 1
        chunks.append(c.finalize())
    return build_file(chunks, next_record_id=rid)


def fx_dirty():
    chunks = []
    rid = 1
    for ci in range(2):
        c = ChunkBuilder()
        for i in range(3):
            when = BASE_TIME + datetime.timedelta(hours=ci, minutes=i)
            c.add_record(rid, when, c.template_record(
                EVENT_GUID, event_tree(),
                event_subs(rid, when, "dirty%d" % rid, 2)))
            rid += 1
        chunks.append(c.finalize())
    # dirty flag set, header undercounts the chunks (stale, as after a crash)
    return build_file(chunks, next_record_id=rid, flags=0x1, declared_chunks=1)


def fx_empty():
    return build_file([], next_record_id=1)


FIXTURES = {
    "basic.evtx": fx_basic,
    "types.evtx": fx_types,
    "nested.evtx": fx_nested,
    "plain.evtx": fx_plain,
    "multichunk.evtx": fx_multichunk,
    "dirty.evtx": fx_dirty,
    "empty.evtx": fx_empty,
}


def main():
    for fname, fn in FIXTURES.items():
        data = fn()
        (HERE / fname).write_bytes(data)
        print("%-18s %6d bytes" % (fname, len(data)))


if __name__ == "__main__":
    main()
