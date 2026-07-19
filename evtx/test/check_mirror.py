# SPDX-License-Identifier: Apache-2.0
#
# Cross-validates mirror.py (the byte-level parse logic destined for
# Evtx.Document.pq) against python-evtx (Willi Ballenthin's reference
# parser) on every fixture in this directory.
#
# The comparison is structural, not textual: both parsers are walked into
# the same canonical post-substitution tree, with values compared raw
# (integers, bytes, FILETIME qwords, SYSTEMTIME words) so that neither
# side's string formatting can mask or cause a mismatch. On top of that,
# every record's rendered XML from the mirror must parse as well-formed XML,
# and a handful of golden assertions pin the extracted analytics columns.
#
#   venv/bin/python check_mirror.py

import struct
import datetime
import xml.etree.ElementTree as ET
from pathlib import Path

import Evtx.Evtx as evtx
import Evtx.Nodes as e_nodes

from mirror import (parse, extract_columns, record_xml, guid_text,
                    filetime_dt)

HERE = Path(__file__).parent

FIXTURES = ["basic.evtx", "types.evtx", "nested.evtx", "plain.evtx",
            "multichunk.evtx", "dirty.evtx", "empty.evtx"]

failures = []


def note(fixture, msg):
    failures.append("%s: %s" % (fixture, msg))
    print("  FAIL %s" % msg)


# ---------------------------------------------------------------------------
# python-evtx -> canonical tree (independent of mirror.py's parsing)
# ---------------------------------------------------------------------------

def canon_variant(sub):
    """Variant node -> ("val", vtype, raw-comparable value) | ("xml", items)."""
    if isinstance(sub, e_nodes.NullTypeNode):
        return ("val", 0x00, None)
    if isinstance(sub, e_nodes.BXmlTypeNode):
        return ("xml", canon_root(sub.root()))
    if isinstance(sub, e_nodes.WstringTypeNode):
        return ("val", 0x01, sub.string())
    if isinstance(sub, e_nodes.StringTypeNode):
        return ("val", 0x02, sub.string())
    if isinstance(sub, e_nodes.SignedByteTypeNode):
        return ("val", 0x03, sub.byte())
    if isinstance(sub, e_nodes.UnsignedByteTypeNode):
        return ("val", 0x04, sub.byte())
    if isinstance(sub, e_nodes.SignedWordTypeNode):
        return ("val", 0x05, sub.word())
    if isinstance(sub, e_nodes.UnsignedWordTypeNode):
        return ("val", 0x06, sub.word())
    if isinstance(sub, e_nodes.SignedDwordTypeNode):
        return ("val", 0x07, sub.dword())
    if isinstance(sub, e_nodes.UnsignedDwordTypeNode):
        return ("val", 0x08, sub.dword())
    if isinstance(sub, e_nodes.SignedQwordTypeNode):
        return ("val", 0x09, sub.qword())
    if isinstance(sub, e_nodes.UnsignedQwordTypeNode):
        return ("val", 0x0A, sub.qword())
    if isinstance(sub, e_nodes.FloatTypeNode):
        return ("val", 0x0B, sub.float())
    if isinstance(sub, e_nodes.DoubleTypeNode):
        return ("val", 0x0C, sub.double())
    if isinstance(sub, e_nodes.BooleanTypeNode):
        return ("val", 0x0D, sub.int32() != 0)
    if isinstance(sub, e_nodes.BinaryTypeNode):
        return ("val", 0x0E, bytes(sub.binary()))
    if isinstance(sub, e_nodes.GuidTypeNode):
        return ("val", 0x0F, guid_text(bytes(sub.unpack_binary(0, 16))))
    if isinstance(sub, e_nodes.SizeTypeNode):
        return ("val", 0x10, sub.num())
    if isinstance(sub, e_nodes.FiletimeTypeNode):
        return ("val", 0x11, sub.unpack_qword(0))
    if isinstance(sub, e_nodes.SystemtimeTypeNode):
        return ("val", 0x12, struct.unpack("<8H", bytes(sub.unpack_binary(0, 16))))
    if isinstance(sub, e_nodes.SIDTypeNode):
        return ("val", 0x13, sub.id())
    if isinstance(sub, e_nodes.Hex32TypeNode):
        return ("val", 0x14, "0x%08x" % sub.unpack_dword(0))
    if isinstance(sub, e_nodes.Hex64TypeNode):
        return ("val", 0x15, "0x%016x" % sub.unpack_qword(0))
    if isinstance(sub, e_nodes.WstringArrayTypeNode):
        raw = bytes(sub.binary())
        parts = raw.decode("utf-16-le").split("\x00")
        if parts and parts[-1] == "":
            parts.pop()
        return ("val", 0x81, parts)
    raise AssertionError("unhandled variant %r" % sub)


def canon_nodes(nodes, subs, chunk):
    items = []
    i = 0
    while i < len(nodes):
        node = nodes[i]
        i += 1
        if isinstance(node, (e_nodes.EndOfStreamNode, e_nodes.StreamStartNode,
                             e_nodes.CloseStartElementNode,
                             e_nodes.CloseEmptyElementNode,
                             e_nodes.CloseElementNode,
                             e_nodes.AttributeNode)):
            continue
        if isinstance(node, e_nodes.OpenStartElementNode):
            attrs = []
            content_nodes = []
            empty = False
            for child in node.children():
                if isinstance(child, e_nodes.AttributeNode):
                    attrs.append((child.attribute_name().string(),
                                  canon_nodes([child.attribute_value()],
                                              subs, chunk)))
                elif isinstance(child, e_nodes.CloseEmptyElementNode):
                    empty = True
                elif isinstance(child, (e_nodes.CloseStartElementNode,
                                        e_nodes.CloseElementNode)):
                    continue
                else:
                    content_nodes.append(child)
            items.append(("elem", node.tag_name(), empty, attrs,
                          canon_nodes(content_nodes, subs, chunk)))
        elif isinstance(node, e_nodes.ValueNode):
            items.append(("text", node.children()[0].string()))
        elif isinstance(node, (e_nodes.NormalSubstitutionNode,
                               e_nodes.ConditionalSubstitutionNode)):
            items.append(canon_variant(subs[node.index()]))
        elif isinstance(node, e_nodes.CharacterReferenceNode):
            items.append(("charref", node.entity()))
        elif isinstance(node, e_nodes.EntityReferenceNode):
            name = chunk.strings()[node.string_offset()].string()
            items.append(("entityref", name))
        elif isinstance(node, e_nodes.ProcessingInstructionTargetNode):
            target = chunk.strings()[node.string_offset()].string()
            data = ""
            if i < len(nodes) and isinstance(nodes[i], e_nodes.ProcessingInstructionDataNode):
                data = nodes[i]._string
                i += 1
            items.append(("pi", target, data))
        else:
            raise AssertionError("unhandled node %r" % node)
    return items


def canon_root(root):
    subs = root.substitutions()
    chunk = root._chunk
    first = root.unpack_byte(0x0) & 0x0F
    nodes = list(root.children())
    has_template = any(isinstance(n, e_nodes.TemplateInstanceNode) for n in nodes)
    if has_template:
        instance = root.template_instance()
        template = chunk.templates()[instance.template_offset()]
        return canon_nodes(list(template.children()), subs, chunk)
    return canon_nodes(nodes, subs, chunk)


# ---------------------------------------------------------------------------
# comparison
# ---------------------------------------------------------------------------

def eq_value(a, b):
    if isinstance(a, float) and isinstance(b, float):
        return a == b or abs(a - b) < 1e-12 * max(abs(a), abs(b))
    return a == b


def diff_items(path, mine, theirs, out):
    if len(mine) != len(theirs):
        out.append("%s: item count %d != %d" % (path, len(mine), len(theirs)))
        return
    for i, (m, t) in enumerate(zip(mine, theirs)):
        p = "%s[%d]" % (path, i)
        if m[0] == "elem" and t[0] == "elem":
            _, mn, me, ma, mc = m
            _, tn, te, ta, tc = t
            if mn != tn:
                out.append("%s: tag %r != %r" % (p, mn, tn))
                continue
            if me != te:
                out.append("%s <%s>: empty %r != %r" % (p, mn, me, te))
            if [a for a, _ in ma] != [a for a, _ in ta]:
                out.append("%s <%s>: attr names %r != %r"
                           % (p, mn, [a for a, _ in ma], [a for a, _ in ta]))
            else:
                for (an, mv), (_, tv) in zip(ma, ta):
                    diff_items("%s <%s>@%s" % (p, mn, an), mv, tv, out)
            diff_items("%s <%s>" % (p, mn), mc, tc, out)
        elif m[0] == "xml" and t[0] == "xml":
            diff_items(p + " (nested)", m[1], t[1], out)
        elif m[0] != t[0]:
            out.append("%s: kind %r != %r" % (p, m[0], t[0]))
        elif m[0] == "val":
            if m[1] != t[1]:
                out.append("%s: value type 0x%02x != 0x%02x" % (p, m[1], t[1]))
            elif not eq_value(m[2], t[2]):
                out.append("%s: value %r != %r" % (p, m[2], t[2]))
        elif m != t:
            out.append("%s: %r != %r" % (p, m, t))


def check_fixture(fname):
    print(fname)
    data = (HERE / fname).read_bytes()
    mine = parse(data, strict=True)

    theirs = []  # (record_id, raw_written, canonical items)
    with evtx.Evtx(str(HERE / fname)) as log:
        fh = log.get_file_header()
        for chunk in fh.chunks(include_inactive=True):
            if not chunk.check_magic():
                continue
            if not chunk.verify():
                note(fname, "python-evtx failed chunk verification")
            for record in chunk.records():
                theirs.append((record.record_num(),
                               record.unpack_qword(0x10),
                               canon_root(record.root())))

    if len(mine["Records"]) != len(theirs):
        note(fname, "record count %d != %d (python-evtx)"
             % (len(mine["Records"]), len(theirs)))
        return

    for rec, (rid, written, items) in zip(mine["Records"], theirs):
        tag = "record %d" % rid
        if rec["RecordId"] != rid:
            note(fname, "%s: id %d != %d" % (tag, rec["RecordId"], rid))
        if rec["Written"] != written:
            note(fname, "%s: written %d != %d" % (tag, rec["Written"], written))
        diffs = []
        diff_items("", rec["Items"], items, diffs)
        for d in diffs[:10]:
            note(fname, "%s: %s" % (tag, d))

        cols = extract_columns(rec)
        try:
            ET.fromstring(cols["Xml"])
        except ET.ParseError as e:
            note(fname, "%s: rendered XML not well-formed: %s" % (tag, e))

    print("  %d records OK against python-evtx" % len(theirs))
    return mine


# ---------------------------------------------------------------------------
# golden assertions on the extracted columns
# ---------------------------------------------------------------------------

def golden(fname, cond, msg):
    if not cond:
        note(fname, "golden: " + msg)


def run_goldens(results):
    basic = results["basic.evtx"]
    cols = [extract_columns(r) for r in basic["Records"]]
    c0 = cols[0]
    golden("basic.evtx", c0["EventId"] == 4624, "EventId 4624, got %r" % c0["EventId"])
    golden("basic.evtx", c0["Provider"] == "PQ-Driverless-Test", "Provider")
    golden("basic.evtx", c0["Level"] == 4 and c0["LevelName"] == "Informational", "Level")
    golden("basic.evtx", c0["Keywords"] == "0x8020000000000000", "Keywords")
    golden("basic.evtx", c0["Channel"] == "Security", "Channel")
    golden("basic.evtx", c0["Computer"] == "PQTEST-HOST.example.local", "Computer")
    golden("basic.evtx", c0["ProcessId"] == 716 and c0["ThreadId"] == 820, "Execution")
    golden("basic.evtx", c0["UserId"] == "S-1-5-21-1111111111-2222222222-3333333333-1001", "UserId")
    golden("basic.evtx", c0["TimeCreated"] == datetime.datetime(2026, 7, 1, 9, 30, 0), "TimeCreated")
    golden("basic.evtx", dict(c0["EventData"]) == {"TargetUserName": "user1", "LogonType": 2},
           "EventData, got %r" % (c0["EventData"],))
    golden("basic.evtx", cols[4]["UserId"] is None, "record 5 has no UserID (conditional null)")
    golden("basic.evtx", 'Guid=""' in cols[2]["Xml"], "record 3 renders empty Guid attribute")

    types_ = results["types.evtx"]
    td = dict(extract_columns(types_["Records"][0])["EventData"])
    golden("types.evtx", td["wstr"] == "héllo wörld ✓", "wstr")
    golden("types.evtx", td["astr"] == "ansi text", "astr")
    golden("types.evtx", td["i64"] == -9007199254740991 and td["u64"] == 9007199254740991, "qwords")
    golden("types.evtx", td["f32"] == 1.5 and td["f64"] == -2.75e10, "floats")
    golden("types.evtx", td["flag"] is True, "bool")
    golden("types.evtx", td["blob"] == bytes(range(16)), "binary")
    golden("types.evtx", td["guid"] == "{5770385F-C22A-43E0-BF4C-06F5698FFBD9}", "guid")
    golden("types.evtx",
           td["ft"] == datetime.datetime(2001, 9, 9, 1, 46, 40, 123456),
           "filetime datetime, got %r" % td["ft"])
    golden("types.evtx",
           td["st"] == datetime.datetime(2026, 7, 18, 23, 59, 58, 999000),
           "systemtime datetime, got %r" % td["st"])
    golden("types.evtx", td["h32"] == "0xdeadbeef" and td["h64"] == "0x8000000000000001", "hex")
    golden("types.evtx", td["sarr"] == ["alpha", "beta", "gamma"], "string array")
    golden("types.evtx", td["gone"] is None, "conditional null")
    golden("types.evtx", td["esc"] == 'a<b&c>"d\'  é✓', "escapable text")
    golden("types.evtx", td["refs"] == "x♫&y", "char/entity refs")
    golden("types.evtx",
           'SystemTime="2026-07-01T09:30:00.0000000Z"' in
           extract_columns(types_["Records"][0])["Xml"],
           "filetime XML rendering")

    nested = results["nested.evtx"]
    nx = extract_columns(nested["Records"][0])["Xml"]
    golden("nested.evtx",
           nx == "<Wrapper><Note>outer</Note><Payload><Inner><Value>42</Value>"
                 "<Label>inner label</Label></Inner></Payload></Wrapper>",
           "nested xml, got %r" % nx)

    plain = results["plain.evtx"]
    px = extract_columns(plain["Records"][0])["Xml"]
    golden("plain.evtx", "<Empty/>" in px and "<?pq-test keep me?>" in px,
           "plain xml, got %r" % px)
    golden("plain.evtx", extract_columns(plain["Records"][0])["EventId"] is None,
           "non-Event root yields null System columns")

    multi = results["multichunk.evtx"]
    golden("multichunk.evtx", [r["RecordId"] for r in multi["Records"]] == list(range(1, 13)),
           "record ids 1..12 across chunks")
    golden("multichunk.evtx", multi["Header"]["ChunkCount"] == 3, "3 chunks")

    dirty = results["dirty.evtx"]
    golden("dirty.evtx", dirty["Header"]["IsDirty"], "dirty flag")
    golden("dirty.evtx", dirty["Header"]["DeclaredChunks"] == 1, "stale declared count")
    golden("dirty.evtx", dirty["Header"]["ChunkCount"] == 2, "signature scan finds both chunks")
    golden("dirty.evtx", len(dirty["Records"]) == 6, "all 6 records recovered")

    empty = results["empty.evtx"]
    golden("empty.evtx", empty["Records"] == [] and empty["Header"]["ChunkCount"] == 0, "empty file")


def main():
    results = {}
    for fname in FIXTURES:
        results[fname] = check_fixture(fname)
    run_goldens(results)
    print()
    if failures:
        print("%d FAILURE(S)" % len(failures))
        raise SystemExit(1)
    print("ALL OK: mirror matches python-evtx on %d fixtures" % len(FIXTURES))


if __name__ == "__main__":
    main()
