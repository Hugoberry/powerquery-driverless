# SPDX-License-Identifier: Apache-2.0
#
# mirror.py — the parse logic destined for Evtx.Document.pq, in pure Python.
#
# Structured the way the M reader will be structured: chunk-relative offsets
# over a buffered binary, a per-chunk prescan of the name-string and template
# tables (with direct-parse fallback), recursive descent over the BinXml
# token stream returning (value, next_position), substitution of template
# placeholders from the per-record value array, then XML rendering and
# System/EventData column extraction from the substituted tree.
#
# Canonical tree (what check_mirror.py compares against python-evtx):
#   element: ("elem", name, empty, [(attr_name, [item...])], [item...])
#   item:    ("text", s) | ("val", vtype, value) | ("charref", n)
#            | ("entityref", name) | ("pi", target, data) | ("cdata", s)
#            | ("xml", [root items...])  -- nested binxml substitution
#
# Value representations mirror the M reader's:
#   wstring/ansi -> str (trailing NULs stripped), ints/floats -> numbers,
#   bool -> bool, binary -> bytes, guid -> "{...}" uppercase, sid -> "S-1-...",
#   hex32/64 -> "0x" + zero-padded lowercase hex, filetime -> raw qword,
#   systemtime -> 8-tuple of words, wstring array -> list of str.

import struct
import datetime

FRAGMENT_HEADER = b"\x0F\x01\x01\x00"


class EvtxError(Exception):
    """Mirror of Error.Record("DataFormat.Error", ...)."""


# ---------------------------------------------------------------------------
# low-level readers (M: U16/U32/U64/Slice over the chunk binary)
# ---------------------------------------------------------------------------

def u8(b, o):
    return b[o]


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def u64(b, o):
    return struct.unpack_from("<Q", b, o)[0]


def utf16_at(b, o, nchars):
    return b[o : o + 2 * nchars].decode("utf-16-le")


# ---------------------------------------------------------------------------
# value decoding (substitution data: size is declared, no prefixes)
# ---------------------------------------------------------------------------

def guid_text(raw):
    d1 = u32(raw, 0)
    d2 = u16(raw, 4)
    d3 = u16(raw, 6)
    tail = raw[8:16]
    return "{%08X-%04X-%04X-%s-%s}" % (
        d1, d2, d3, tail[:2].hex().upper(), tail[2:].hex().upper())


def sid_text(raw):
    revision = raw[0]
    count = raw[1]
    authority = int.from_bytes(raw[2:8], "big")
    parts = ["S", str(revision), str(authority)]
    for i in range(count):
        parts.append(str(u32(raw, 8 + 4 * i)))
    return "-".join(parts)


def decode_value(chunk, pos, size, vtype, names, templates, encoding, strict):
    """Decode one substitution value; returns a canonical item."""
    raw = bytes(chunk[pos : pos + size])
    if vtype == 0x00:
        return ("val", 0x00, None)
    if vtype == 0x01:
        return ("val", vtype, raw.decode("utf-16-le").rstrip("\x00"))
    if vtype == 0x02:
        return ("val", vtype, raw.decode(encoding).rstrip("\x00"))
    if vtype == 0x03:
        return ("val", vtype, struct.unpack("<b", raw)[0])
    if vtype == 0x04:
        return ("val", vtype, raw[0])
    if vtype == 0x05:
        return ("val", vtype, struct.unpack("<h", raw)[0])
    if vtype == 0x06:
        return ("val", vtype, u16(raw, 0))
    if vtype == 0x07:
        return ("val", vtype, struct.unpack("<i", raw)[0])
    if vtype == 0x08:
        return ("val", vtype, u32(raw, 0))
    if vtype == 0x09:
        return ("val", vtype, struct.unpack("<q", raw)[0])
    if vtype == 0x0A:
        return ("val", vtype, u64(raw, 0))
    if vtype == 0x0B:
        return ("val", vtype, struct.unpack("<f", raw)[0])
    if vtype == 0x0C:
        return ("val", vtype, struct.unpack("<d", raw)[0])
    if vtype == 0x0D:
        return ("val", vtype, struct.unpack("<i", raw)[0] != 0)
    if vtype == 0x0E:
        return ("val", vtype, raw)
    if vtype == 0x0F:
        return ("val", vtype, guid_text(raw))
    if vtype == 0x10:
        return ("val", vtype, u32(raw, 0) if size == 4 else u64(raw, 0))
    if vtype == 0x11:
        return ("val", vtype, u64(raw, 0))
    if vtype == 0x12:
        return ("val", vtype, struct.unpack("<8H", raw))
    if vtype == 0x13:
        return ("val", vtype, sid_text(raw))
    if vtype == 0x14:
        return ("val", vtype, "0x%08x" % u32(raw, 0))
    if vtype == 0x15:
        return ("val", vtype, "0x%016x" % u64(raw, 0))
    if vtype == 0x21:
        items, _ = parse_root(chunk, pos, names, templates, encoding, strict)
        return ("xml", items)
    if vtype == 0x81:
        text = raw.decode("utf-16-le")
        parts = text.split("\x00")
        if parts and parts[-1] == "":
            parts.pop()
        return ("val", vtype, parts)
    if strict:
        raise EvtxError("unsupported substitution value type 0x%02x" % vtype)
    return ("val", vtype, raw)  # permissive: keep the raw bytes


# ---------------------------------------------------------------------------
# chunk prescans (M: records keyed by Text.From(offset), lazily evaluated)
# ---------------------------------------------------------------------------

def parse_name_at(chunk, off):
    """Name string: next_offset(4) hash(2) nchars(2) utf16 nul(2).
    Returns (name, byte_length)."""
    nchars = u16(chunk, off + 6)
    return utf16_at(chunk, off + 8, nchars), 8 + 2 * nchars + 2


def prescan_names(chunk):
    names = {}
    for i in range(64):
        off = u32(chunk, 0x80 + 4 * i)
        while off > 0 and off < 0x10000:
            name, _ = parse_name_at(chunk, off)
            names[off] = name
            off = u32(chunk, off)  # next in bucket chain
    return names


def prescan_template_offsets(chunk):
    offsets = []
    for i in range(32):
        off = u32(chunk, 0x180 + 4 * i)
        while off > 0 and off < 0x10000:
            offsets.append(off)
            off = u32(chunk, off)  # definition's next-offset field
    return offsets


def lookup_name(chunk, names, off):
    if off in names:
        return names[off]
    return parse_name_at(chunk, off)[0]  # fallback: dirty string table


# ---------------------------------------------------------------------------
# BinXml token stream -> pre-substitution tree
# ---------------------------------------------------------------------------

def parse_value_item(chunk, pos, names):
    """One attribute-value / content scalar token. Returns (item, next, more)
    where more is the 0x40 'more data follows' flag."""
    tok = u8(chunk, pos)
    kind = tok & 0x0F
    more = (tok & 0x40) != 0
    if kind == 0x05:
        vtype = u8(chunk, pos + 1)
        if vtype != 0x01:
            raise EvtxError("value token with non-string type 0x%02x" % vtype)
        nchars = u16(chunk, pos + 2)
        return ("text", utf16_at(chunk, pos + 4, nchars)), pos + 4 + 2 * nchars, more
    if kind == 0x0D or kind == 0x0E:
        index = u16(chunk, pos + 1)
        vtype = u8(chunk, pos + 3)
        return ("sub", index, vtype, kind == 0x0E), pos + 4, more
    if kind == 0x08:
        return ("charref", u16(chunk, pos + 1)), pos + 3, more
    if kind == 0x09:
        name_off = u32(chunk, pos + 1)
        nxt = pos + 5
        if name_off == nxt:
            _, nlen = parse_name_at(chunk, name_off)
            nxt += nlen
        return ("entityref", lookup_name(chunk, names, name_off)), nxt, more
    raise EvtxError("unexpected token 0x%02x in value position" % tok)


def parse_element(chunk, pos, names):
    tok = u8(chunk, pos)
    has_attrs = (tok & 0x40) != 0
    name_off = u32(chunk, pos + 7)
    pos2 = pos + 11
    if name_off == pos2:
        _, nlen = parse_name_at(chunk, name_off)
        pos2 += nlen
    name = lookup_name(chunk, names, name_off)
    attrs = []
    if has_attrs:
        pos2 += 4  # attribute list size (traversal does not need it)
        while (u8(chunk, pos2) & 0x0F) == 0x06:
            atok = u8(chunk, pos2)
            aname_off = u32(chunk, pos2 + 1)
            pos2 += 5
            if aname_off == pos2:
                _, nlen = parse_name_at(chunk, aname_off)
                pos2 += nlen
            aname = lookup_name(chunk, names, aname_off)
            parts = []
            more = True
            while more:
                item, pos2, more = parse_value_item(chunk, pos2, names)
                parts.append(item)
            attrs.append((aname, parts))
            if (atok & 0x40) == 0:
                break
    close = u8(chunk, pos2)
    if close == 0x03:
        return ("elem", name, True, attrs, []), pos2 + 1
    if close != 0x02:
        raise EvtxError("expected close-start-element, found 0x%02x" % close)
    content, pos3 = parse_content(chunk, pos2 + 1, names)
    return ("elem", name, False, attrs, content), pos3


def parse_content(chunk, pos, names):
    """Element content: items until the 0x04 end-element token (consumed)."""
    items = []
    while True:
        tok = u8(chunk, pos)
        kind = tok & 0x0F
        if kind == 0x04:
            return items, pos + 1
        if kind == 0x01:
            el, pos = parse_element(chunk, pos, names)
            items.append(el)
        elif kind in (0x05, 0x0D, 0x0E, 0x08, 0x09):
            item, pos, _ = parse_value_item(chunk, pos, names)
            items.append(item)
        elif kind == 0x07:
            nchars = u16(chunk, pos + 1)
            items.append(("cdata", utf16_at(chunk, pos + 3, nchars)))
            pos += 3 + 2 * nchars
        elif kind == 0x0A:
            name_off = u32(chunk, pos + 1)
            pos += 5
            if name_off == pos:
                _, nlen = parse_name_at(chunk, name_off)
                pos += nlen
            target = lookup_name(chunk, names, name_off)
            data = ""
            if u8(chunk, pos) & 0x0F == 0x0B:
                nchars = u16(chunk, pos + 1)
                data = utf16_at(chunk, pos + 3, nchars)
                pos += 3 + 2 * nchars
            items.append(("pi", target, data))
        else:
            raise EvtxError("unexpected token 0x%02x in element content" % tok)


def parse_fragment_items(chunk, pos, names):
    """Fragment body: elements/values until the 0x00 EOF token (consumed)."""
    items = []
    while True:
        tok = u8(chunk, pos)
        kind = tok & 0x0F
        if kind == 0x00:
            return items, pos + 1
        if kind == 0x01:
            el, pos = parse_element(chunk, pos, names)
            items.append(el)
        elif kind in (0x05, 0x0D, 0x0E, 0x08, 0x09):
            item, pos, _ = parse_value_item(chunk, pos, names)
            items.append(item)
        else:
            raise EvtxError("unexpected token 0x%02x at fragment level" % tok)


def parse_template_body(chunk, def_off, names):
    """Template definition: next(4) guid(16) data_size(4) fragment."""
    body = def_off + 24
    if bytes(chunk[body : body + 4]) != FRAGMENT_HEADER:
        raise EvtxError("template definition does not start with a fragment header")
    items, _ = parse_fragment_items(chunk, body + 4, names)
    return items


# ---------------------------------------------------------------------------
# substitution
# ---------------------------------------------------------------------------

def parse_subdata(chunk, pos, names, templates, encoding, strict):
    count = u32(chunk, pos)
    pos += 4
    decls = []
    for i in range(count):
        decls.append((u16(chunk, pos), u8(chunk, pos + 2)))
        pos += 4
    values = []
    for size, vtype in decls:
        if vtype == 0x00:
            values.append(("val", 0x00, None))
        elif size == 0 and vtype not in (0x01, 0x02, 0x0E, 0x81):
            values.append(("val", 0x00, None))  # zero-size fixed value
        else:
            values.append(decode_value(chunk, pos, size, vtype, names,
                                       templates, encoding, strict))
        pos += size
    return values, pos


def substitute(items, values):
    out = []
    for item in items:
        if item[0] == "elem":
            _, name, empty, attrs, content = item
            new_attrs = [(a, [resolve(p, values) for p in parts])
                         for a, parts in attrs]
            out.append(("elem", name, empty, new_attrs,
                        substitute(content, values)))
        else:
            out.append(resolve(item, values))
    return out


def resolve(item, values):
    if item[0] == "sub":
        _, index, _, _ = item
        if index >= len(values):
            raise EvtxError("substitution index %d out of range" % index)
        return values[index]
    return item


# ---------------------------------------------------------------------------
# roots, records, chunks, file
# ---------------------------------------------------------------------------

def parse_root(chunk, pos, names, templates, encoding, strict):
    """A binxml root: [fragment header] (template instance | direct items),
    then the substitution array. Returns (items, next)."""
    if bytes(chunk[pos : pos + 4]) == FRAGMENT_HEADER:
        pos += 4
    tok = u8(chunk, pos)
    if (tok & 0x0F) == 0x0C:
        def_off = u32(chunk, pos + 6)
        pos += 10
        if def_off == pos:  # resident definition: skip over it
            data_size = u32(chunk, def_off + 20)
            pos = def_off + 24 + data_size
        if def_off in templates:
            template_items = templates[def_off]
        else:  # fallback: definition not linked in the template table
            template_items = parse_template_body(chunk, def_off, names)
        values, pos = parse_subdata(chunk, pos, names, templates, encoding, strict)
        return substitute(template_items, values), pos
    items, pos = parse_fragment_items(chunk, pos, names)
    values, pos = parse_subdata(chunk, pos, names, templates, encoding, strict)
    return substitute(items, values), pos


def parse_chunk(chunk, encoding, strict):
    names = prescan_names(chunk)
    templates = {}
    for off in prescan_template_offsets(chunk):
        templates[off] = parse_template_body(chunk, off, names)
    free = u32(chunk, 0x30)  # next_record_offset
    records = []
    pos = 0x200
    while pos + 28 <= free:
        if u32(chunk, pos) != 0x00002A2A:
            if strict and pos < free:
                raise EvtxError("bad record signature at chunk offset %d" % pos)
            break
        size = u32(chunk, pos + 4)
        if size < 28 or pos + size > free:
            if strict:
                raise EvtxError("bad record size %d at chunk offset %d" % (size, pos))
            break
        if u32(chunk, pos + size - 4) != size:
            if strict:
                raise EvtxError("record size copy mismatch at chunk offset %d" % pos)
            break
        record_id = u64(chunk, pos + 8)
        written = u64(chunk, pos + 16)
        try:
            items, _ = parse_root(chunk, pos + 24, names, templates,
                                  encoding, strict)
            records.append({"RecordId": record_id, "Written": written,
                            "Items": items})
        except EvtxError:
            if strict:
                raise
            # permissive: skip the record, keep walking (sizes are intact)
        pos += size
    return records


def parse(data, encoding="cp1252", strict=True):
    if len(data) < 4096 or data[0:8] != b"ElfFile\x00":
        raise EvtxError("not an EVTX file (missing ElfFile signature)")
    major = u16(data, 0x26)
    if major != 3:
        raise EvtxError("unsupported EVTX major version %d" % major)
    flags = u32(data, 0x78)
    header = {
        "NextRecordId": u64(data, 0x18),
        "DeclaredChunks": u16(data, 0x2A),
        "IsDirty": flags & 1 == 1,
        "IsFull": flags & 2 == 2,
        "Version": "%d.%d" % (major, u16(data, 0x24)),
    }
    slots = (len(data) - 4096) // 0x10000
    records = []
    chunk_count = 0
    for i in range(slots):
        base = 4096 + 0x10000 * i
        if data[base : base + 8] != b"ElfChnk\x00":
            continue
        chunk_count += 1
        records.extend(parse_chunk(data[base : base + 0x10000],
                                   encoding, strict))
    header["ChunkCount"] = chunk_count
    return {"Header": header, "Records": records}


# ---------------------------------------------------------------------------
# rendering and column extraction (the M reader's output conventions)
# ---------------------------------------------------------------------------

FILETIME_EPOCH = datetime.datetime(1601, 1, 1)


def filetime_dt(qword):
    # the M reader keeps the full 100ns tick; Python datetime stops at 1us
    return FILETIME_EPOCH + datetime.timedelta(microseconds=qword // 10)


def filetime_text(qword):
    dt = FILETIME_EPOCH + datetime.timedelta(microseconds=qword // 10)
    frac = qword % 10_000_000
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + (".%07dZ" % frac)


def systemtime_dt(words):
    y, mo, _, d, h, mi, s, ms = words
    return datetime.datetime(y, mo, d, h, mi, s, ms * 1000)


def systemtime_text(words):
    y, mo, _, d, h, mi, s, ms = words
    return "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ" % (y, mo, d, h, mi, s, ms)


def number_text(v):
    if isinstance(v, float):
        return str(int(v)) if v == int(v) and abs(v) < 1e16 else repr(v)
    return str(v)


def value_text(vtype, v):
    """The text a value contributes to rendered XML (pre-escaping)."""
    if v is None:
        return ""
    if vtype in (0x01, 0x02, 0x0F, 0x13, 0x14, 0x15):
        return v
    if vtype == 0x0D:
        return "true" if v else "false"
    if vtype == 0x0E:
        return v.hex().upper()
    if vtype == 0x11:
        return filetime_text(v)
    if vtype == 0x12:
        return systemtime_text(v)
    if vtype == 0x81:
        return "\n".join(v)
    if isinstance(v, bytes):
        return v.hex().upper()
    return number_text(v)


def esc_text(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def esc_attr(s):
    return esc_text(s).replace('"', "&quot;")


def item_xml(item, in_attr):
    kind = item[0]
    if kind == "text":
        return esc_attr(item[1]) if in_attr else esc_text(item[1])
    if kind == "val":
        t = value_text(item[1], item[2])
        return esc_attr(t) if in_attr else esc_text(t)
    if kind == "charref":
        return "&#x%x;" % item[1]
    if kind == "entityref":
        return "&%s;" % item[1]
    if kind == "cdata":
        return "<![CDATA[%s]]>" % item[1]
    if kind == "pi":
        return "<?%s %s?>" % (item[1], item[2])
    if kind == "xml":
        return "".join(item_xml(i, False) for i in item[1])
    if kind == "elem":
        return elem_xml(item)
    raise EvtxError("unrenderable item %r" % (kind,))


def elem_xml(el):
    _, name, empty, attrs, content = el
    out = ["<", name]
    for aname, parts in attrs:
        out.append(' %s="%s"' % (aname, "".join(item_xml(p, True) for p in parts)))
    if empty:
        out.append("/>")
        return "".join(out)
    out.append(">")
    for item in content:
        out.append(item_xml(item, False))
    out.append("</%s>" % name)
    return "".join(out)


def record_xml(items):
    return "".join(item_xml(i, False) for i in items)


# -- column extraction -------------------------------------------------------

LEVEL_NAMES = {0: "LogAlways", 1: "Critical", 2: "Error", 3: "Warning",
               4: "Informational", 5: "Verbose"}


def child_elems(el, name=None):
    return [c for c in el[4]
            if c[0] == "elem" and (name is None or c[1] == name)]


def attr_of(el, name):
    for aname, parts in el[3]:
        if aname == name:
            return parts
    return None


def typed_value(vtype, v):
    """A single substituted value as the M reader surfaces it in EventData
    and the System columns: dates become datetimes, the rest stay typed."""
    if v is None:
        return None
    if vtype == 0x11:
        return filetime_dt(v)
    if vtype == 0x12:
        return systemtime_dt(v)
    return v


def scalar_of(parts):
    """The typed value of an attribute or an element's content."""
    if parts is None:
        return None
    vals = [p for p in parts if p[0] in ("text", "val", "charref", "entityref")]
    if len(vals) == 1 and vals[0][0] == "val":
        return typed_value(vals[0][1], vals[0][2])
    if not vals:
        return None
    out = []
    for p in vals:
        if p[0] == "text":
            out.append(p[1])
        elif p[0] == "val":
            out.append(value_text(p[1], p[2]))
        elif p[0] == "charref":
            out.append(chr(p[1]))
        else:
            out.append({"lt": "<", "gt": ">", "amp": "&",
                        "quot": '"', "apos": "'"}.get(p[1], ""))
    return "".join(out)


def elem_scalar(el):
    return scalar_of(el[4]) if el is not None else None


def first(lst):
    return lst[0] if lst else None


def as_int(v):
    if v is None:
        return None
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return int(v)
    try:
        return int(str(v).strip())
    except ValueError:
        return None


def keywords_text(v):
    if v is None:
        return None
    if isinstance(v, int):
        return "0x%016x" % v
    return str(v)


def time_of(parts, fallback_qword):
    v = scalar_of(parts) if parts else None
    if isinstance(v, datetime.datetime):
        return v
    if isinstance(v, str):
        try:
            return datetime.datetime.fromisoformat(v.rstrip("Z"))
        except ValueError:
            pass
    return filetime_dt(fallback_qword)


def event_data_record(event):
    """EventData/UserData -> ordered (key, value) pairs."""
    holder = first(child_elems(event, "EventData"))
    if holder is None:
        ud = first(child_elems(event, "UserData"))
        if ud is None:
            return None
        inner = first(child_elems(ud))
        holder = inner if inner is not None else ud
    pairs = []
    used = {}
    for i, c in enumerate(child_elems(holder)):
        key = None
        if c[1] == "Data":
            key = scalar_of(attr_of(c, "Name"))
        if key is None or key == "":
            key = c[1] if c[1] != "Data" else "Data%d" % (i + 1)
        if key in used:
            used[key] += 1
            key = "%s%d" % (key, used[key])
        else:
            used[key] = 1
        pairs.append((key, elem_scalar(c)))
    return pairs


def extract_columns(rec):
    items = rec["Items"]
    event = None
    for it in items:
        if it[0] == "elem":
            event = it
            break
    system = first(child_elems(event, "System")) if event is not None and event[1] == "Event" else None
    provider = first(child_elems(system, "Provider")) if system else None
    execution = first(child_elems(system, "Execution")) if system else None
    security = first(child_elems(system, "Security")) if system else None
    tc = first(child_elems(system, "TimeCreated")) if system else None
    level = as_int(elem_scalar(first(child_elems(system, "Level")))) if system else None
    cols = {
        "RecordId": rec["RecordId"],
        "TimeCreated": time_of(attr_of(tc, "SystemTime") if tc else None,
                               rec["Written"]),
        "Provider": scalar_of(attr_of(provider, "Name")) if provider else None,
        "EventId": as_int(elem_scalar(first(child_elems(system, "EventID")))) if system else None,
        "Level": level,
        "LevelName": LEVEL_NAMES.get(level) if level is not None else None,
        "Task": as_int(elem_scalar(first(child_elems(system, "Task")))) if system else None,
        "Opcode": as_int(elem_scalar(first(child_elems(system, "Opcode")))) if system else None,
        "Keywords": keywords_text(elem_scalar(first(child_elems(system, "Keywords")))) if system else None,
        "Channel": elem_scalar(first(child_elems(system, "Channel"))) if system else None,
        "Computer": elem_scalar(first(child_elems(system, "Computer"))) if system else None,
        "ProcessId": as_int(scalar_of(attr_of(execution, "ProcessID"))) if execution else None,
        "ThreadId": as_int(scalar_of(attr_of(execution, "ThreadID"))) if execution else None,
        "UserId": scalar_of(attr_of(security, "UserID")) if security else None,
        "EventData": event_data_record(event) if event is not None and event[1] == "Event" else None,
        "Xml": record_xml(items),
    }
    return cols
