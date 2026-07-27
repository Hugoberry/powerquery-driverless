#!/usr/bin/env python3
"""
hyperparse.py - a reverse-engineered reader for Tableau .hyper files.

Parses the CONTAINER layer (superblocks, packages, system catalog) without
Tableau's Hyper API, and takes a heuristic pass at the Data Block layer.

  python3 hyperparse.py FILE...                  summary + catalog
  python3 hyperparse.py --blocks FILE            also hunt for Data Blocks
  python3 hyperparse.py --json FILE              machine-readable output
  python3 hyperparse.py --verify FILE            cross-check vs the real API
  python3 hyperparse.py --dump 0x2000 FILE       hexdump at an offset

No third-party dependencies: the LZ4 block decoder is implemented inline.
If `tableauhyperapi` happens to be installed, --verify uses it as an oracle.

CONFIDENCE LEVELS
  Container layer (superblocks, packages, catalog) - well established across
  format versions 0-4, builds around 0.0.25xxx, and files from 64 KiB to 4.5 MB.
  Data Block layer - heuristic. Field *names* follow Lang et al., "Data Blocks"
  (SIGMOD 2016, TUM), but Tableau's on-disk order does not match the paper
  exactly, so offsets are reported raw. Treat as a lead, not as truth.

Known-unknown: the 32-bit digests. CRC-32, CRC-32C, XXH32, XXH64-lo and
XXH3-lo have all been ruled out over every plausible byte range. They are
read and reported but never verified.
"""

from __future__ import annotations

import argparse
import json
import re
import struct
import sys
import uuid
from dataclasses import dataclass, field, asdict
from typing import Any

PAGE_SIZE = 0x1000
EXTENT_SIZE = 0x10000            # files are always a whole number of these
SB_MAGIC = b"Hyper\x08\x00\x00"
PKG_MAGIC = b"HyperDB\x00"
CATALOG_NEEDLE = b'{"compressionMethod'
SB_CHECKSUM_OFF = 0x0FFC


# --------------------------------------------------------------------------
# LZ4 block format (raw, no frame header - Hyper does not use frames)
# --------------------------------------------------------------------------

def lz4_block_decode(src: bytes, start: int = 0, limit: int = 1 << 24) -> tuple[bytes, int]:
    """Decode as far as the stream stays self-consistent; return (out, end).

    Deliberately tolerant: a normal decoder needs the output size up front and
    raises on the first inconsistency. For exploration we want to decode until
    the stream stops making sense and learn where that happened.
    """
    out = bytearray()
    i, n = start, len(src)
    while i < n and len(out) < limit:
        token = src[i]; i += 1
        lit = token >> 4
        if lit == 15:
            while i < n:
                b = src[i]; i += 1
                lit += b
                if b != 255:
                    break
            else:
                break
        if i + lit > n:
            break
        out += src[i:i + lit]
        i += lit
        if i + 2 > n:
            break                                  # legal: block ends on literals
        offset = src[i] | (src[i + 1] << 8)
        i += 2
        if offset == 0 or offset > len(out):
            i -= 2
            break                                  # bad back-reference: stop clean
        match = token & 0x0F
        if match == 15:
            while i < n:
                b = src[i]; i += 1
                match += b
                if b != 255:
                    break
            else:
                break
        match += 4
        p = len(out) - offset
        for _ in range(match):                     # byte-wise: overlap is legal
            out.append(out[p]); p += 1
    return bytes(out), i


# --------------------------------------------------------------------------
# Structures
# --------------------------------------------------------------------------

@dataclass
class Superblock:
    offset: int
    struct_version: int
    format_version: int
    creator_build: int
    min_compatible_build: int
    txn_id: int
    file_size: int
    ptr_root: int                 # relocates every commit; target starts 08 00...
    counter_a: int                # NOT an offset - see module docstring
    counter_b: int
    commit_id: int
    checksum: int
    unknown_tail: str             # hex of any non-zero bytes we do not model

    @property
    def page_index(self) -> int:
        return self.offset // PAGE_SIZE


@dataclass
class PackageHeader:
    offset: int
    kind: int
    struct_version: int
    format_version: int
    database_uuid: str
    checksum: int


@dataclass
class Catalog:
    offset: int
    length: int
    digest: int
    framing: str                  # "packaged" | "bare"
    package: PackageHeader | None
    data: dict


@dataclass
class DataBlockGuess:
    offset: int
    compressed_len: int
    decoded_len: int
    tuple_count: int
    header_fields: list[int]
    sma_min: Any
    sma_max: Any
    strings: list[str]


@dataclass
class HyperFile:
    path: str
    size: int
    superblocks: list[Superblock] = field(default_factory=list)
    catalogs: list[Catalog] = field(default_factory=list)
    blocks: list[DataBlockGuess] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def live(self) -> Superblock | None:
        return max(self.superblocks, key=lambda s: s.txn_id) if self.superblocks else None


# --------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------

def _u(fmt: str, d: bytes, off: int) -> int:
    return struct.unpack_from(fmt, d, off)[0]


def parse_superblock(d: bytes, base: int, warn) -> Superblock | None:
    if len(d) < base + PAGE_SIZE:
        warn(f"file too short for superblock at {base:#x}")
        return None
    if d[base:base + 8] != SB_MAGIC:
        warn(f"bad superblock magic at {base:#x}: {d[base:base+8]!r}")
        return None

    # Flag any non-zero byte in regions we believe are reserved, so that a file
    # from a newer build tells us it has fields we do not know about.
    unknown = bytearray()
    for lo, hi in ((0x0C, 0x20), (0x58, 0x60), (0x68, 0x80)):
        chunk = d[base + lo: base + hi]
        if any(chunk):
            unknown += chunk
    if any(d[base + 0x80: base + SB_CHECKSUM_OFF]):
        warn(f"superblock {base:#x}: unexpected data in 0x80..0xFFC")

    return Superblock(
        offset=base,
        struct_version=_u("<H", d, base + 0x08),
        format_version=_u("<H", d, base + 0x0A),
        creator_build=_u("<Q", d, base + 0x20),
        min_compatible_build=_u("<I", d, base + 0x2C),
        txn_id=_u("<Q", d, base + 0x30),
        file_size=_u("<Q", d, base + 0x38),
        ptr_root=_u("<Q", d, base + 0x40),
        counter_a=_u("<Q", d, base + 0x48),
        counter_b=_u("<Q", d, base + 0x50),
        commit_id=_u("<Q", d, base + 0x60),
        checksum=_u("<I", d, base + SB_CHECKSUM_OFF),
        unknown_tail=unknown.hex(),
    )


def parse_package(d: bytes, off: int) -> PackageHeader | None:
    if off < 0 or off + 0x40 > len(d) or d[off:off + 8] != PKG_MAGIC:
        return None
    return PackageHeader(
        offset=off,
        kind=_u("<I", d, off + 0x08),
        struct_version=_u("<H", d, off + 0x0C),
        format_version=_u("<H", d, off + 0x0E),
        database_uuid=str(uuid.UUID(bytes_le=d[off + 0x10:off + 0x20])),
        checksum=_u("<I", d, off + 0x30),
    )


def brace_match(d: bytes, start: int) -> int:
    """End offset of the JSON object at `start`. Length is stored nowhere, so
    the blob is delimited purely structurally. String and escape aware."""
    depth = 0
    in_str = False
    esc = False
    i = start
    while i < len(d):
        c = d[i]
        if in_str:
            if esc:
                esc = False
            elif c == 0x5C:
                esc = True
            elif c == 0x22:
                in_str = False
        elif c == 0x22:
            in_str = True
        elif c == 0x7B:
            depth += 1
        elif c == 0x7D:
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError(f"unterminated catalog JSON at {start:#x}")


def find_catalogs(d: bytes, warn) -> list[Catalog]:
    out: list[Catalog] = []
    pos = 0
    while True:
        pos = d.find(CATALOG_NEEDLE, pos)
        if pos < 0:
            return out
        try:
            end = brace_match(d, pos)
            payload = json.loads(d[pos:end])
        except (ValueError, json.JSONDecodeError) as e:
            warn(f"catalog at {pos:#x} failed to parse: {e}")
            pos += len(CATALOG_NEEDLE)
            continue
        pkg = parse_package(d, pos - 0x40)
        out.append(Catalog(
            offset=pos,
            length=end - pos,
            digest=_u("<I", d, end) if end + 4 <= len(d) else 0,
            framing="packaged" if pkg else "bare",
            package=pkg,
            data=payload,
        ))
        pos = end


SMA_SLOT = 16          # min and max each occupy a 16-byte aligned slot


def _read_sma(b: bytes, off: int) -> Any:
    """Decode one SMA slot.

    Two shapes observed. Variable-length types (Varchar) store a u4 byte length
    followed by the raw text, NUL-padded to a 16-byte boundary. Fixed-width
    types (Integer, Date, Double, Timestamp) store the value directly, so we
    surface both the u8 and the raw bytes and let the caller decide.
    """
    if off + SMA_SLOT > len(b):
        return None
    slot = b[off:off + SMA_SLOT]
    n = _u("<I", b, off)
    if 0 < n <= SMA_SLOT - 4:
        raw = slot[4:4 + n]
        if all(32 <= c < 127 for c in raw):
            return raw.decode("ascii")
    # Longer strings spill past one slot; accept those too if printable.
    if 0 < n <= 4096 and off + 4 + n <= len(b):
        raw = b[off + 4: off + 4 + n]
        if raw and all(32 <= c < 127 for c in raw):
            return raw.decode("ascii")
    return {"u8": _u("<Q", b, off), "raw": slot[:8].hex()}


def _sma_span(b: bytes, off: int) -> int:
    """Bytes consumed by the SMA slot at `off`, rounded up to SMA_SLOT."""
    n = _u("<I", b, off) if off + 4 <= len(b) else 0
    if 0 < n <= 4096:
        return max(SMA_SLOT, -(-(4 + n) // SMA_SLOT) * SMA_SLOT)
    return SMA_SLOT


def find_data_blocks(d: bytes, lo: int, hi: int, max_hits: int, warn) -> list[DataBlockGuess]:
    """Heuristic sweep for LZ4-compressed Data Blocks.

    A candidate is accepted when the decoded prefix looks like a block header:
    a plausible tuple count followed by offsets that stay inside the block.
    """
    hits: list[DataBlockGuess] = []
    seen: list[int] = []
    for start in range(lo, min(hi, len(d))):
        out, end = lz4_block_decode(d, start, limit=1 << 20)
        if len(out) < 64 or end - start < 32:
            continue
        tuple_count = _u("<Q", out, 0)
        if not (1 <= tuple_count <= 1 << 32):
            continue
        fields = [_u("<Q", out, 8 + 8 * k) for k in range(min(5, (len(out) - 8) // 8))]
        inside = [f for f in fields if 0 < f < len(out)]
        if len(inside) < 2:
            continue
        if any(abs(start - s) < 64 for s in seen):
            continue
        seen.append(start)

        # Header is 8 bytes of tuple count plus 5 u64 per attribute; the SMA
        # pair follows. Try the single-attribute case, which is what we can
        # verify. Anything else is reported as raw fields only.
        smin = _read_sma(out, 48)
        smax = _read_sma(out, 48 + _sma_span(out, 48))
        strings = [s.decode() for s in re.findall(rb"[ -~]{4,}", out)][:12]

        hits.append(DataBlockGuess(
            offset=start, compressed_len=end - start, decoded_len=len(out),
            tuple_count=tuple_count, header_fields=fields,
            sma_min=smin, sma_max=smax, strings=strings,
        ))
        if len(hits) >= max_hits:
            warn(f"data block sweep hit the {max_hits}-block cap; use --max-blocks")
            break
    return hits


def parse(path: str, want_blocks: bool = False, max_blocks: int = 40) -> HyperFile:
    with open(path, "rb") as fh:
        d = fh.read()

    hf = HyperFile(path=path, size=len(d))
    warn = hf.warnings.append

    if len(d) < 2 * PAGE_SIZE:
        warn("file smaller than two pages; not a .hyper file?")
        return hf
    if len(d) % EXTENT_SIZE:
        warn(f"size {len(d)} is not a multiple of {EXTENT_SIZE}; expected whole 64 KiB extents")

    for base in (0, PAGE_SIZE):
        sb = parse_superblock(d, base, warn)
        if sb:
            hf.superblocks.append(sb)

    live = hf.live
    if live:
        if live.file_size != len(d):
            warn(f"live superblock says file_size={live.file_size:#x} but file is {len(d):#x}")
        for sb in hf.superblocks:
            if sb.txn_id % 2 != sb.page_index:
                warn(f"superblock {sb.offset:#x}: txn {sb.txn_id} breaks the "
                     f"txn_id%2 == page_index rule")
        if len({s.format_version for s in hf.superblocks}) > 1:
            warn("superblocks disagree on format version")
        if live.format_version > 4:
            warn(f"format version {live.format_version} is newer than anything tested (0-4)")

    hf.catalogs = find_catalogs(d, warn)
    if not hf.catalogs:
        warn("no system catalog found")

    if want_blocks:
        start = 2 * PAGE_SIZE
        hf.blocks = find_data_blocks(d, start, len(d), max_blocks, warn)

    return hf


# --------------------------------------------------------------------------
# Reporting
# --------------------------------------------------------------------------

NAMESPACE_PARENT_BASE = 32   # relation["parent"] == 32 + index into namespaces


def relations(cat: Catalog, warn=None) -> list[dict]:
    """Relations from a catalog, each annotated with its resolved schema.

    A relation names its schema through `parent`, which is an index into the
    catalog's namespaces array biased by 32 (the low oids appear to be reserved
    for built-ins). Table names are NOT unique within a file - only
    (schema, name) is - so always key on the pair.
    """
    out = []
    spaces = cat.data.get("namespaces", []) or []
    for r in cat.data.get("relations", []) or []:
        idx = r.get("parent", -1) - NAMESPACE_PARENT_BASE
        if 0 <= idx < len(spaces):
            schema = spaces[idx]["name"]
        else:
            schema = "?"
            if warn:
                warn(f"relation {r.get('name')!r}: parent={r.get('parent')} does not "
                     f"index the {len(spaces)} namespaces; schema unresolved")
        out.append({**r, "_schema": schema})
    return out


def qualified(r: dict) -> str:
    return f'"{r["_schema"]}"."{r["name"]}"'


def report(hf: HyperFile, show_blocks: bool) -> None:
    hf_warn = hf.warnings.append
    print(f"\n{'=' * 78}\n{hf.path}\n{'=' * 78}")
    print(f"  size            {hf.size:,} bytes ({hf.size:#x}) = "
          f"{hf.size // EXTENT_SIZE} x 64KiB extent(s), {hf.size // PAGE_SIZE} pages")

    for sb in hf.superblocks:
        tag = "LIVE " if sb is hf.live else "stale"
        print(f"  [{tag}] page {sb.page_index}  txn={sb.txn_id:<4} fmt=v{sb.format_version} "
              f"build={sb.creator_build}  file_size={sb.file_size:#x}")
        print(f"          root={sb.ptr_root:#x}  counters=({sb.counter_a},{sb.counter_b})  "
              f"commit_id={sb.commit_id:#018x}  digest={sb.checksum:#010x} (unverified)")
        if sb.unknown_tail:
            print(f"          !! unmodelled non-zero bytes: {sb.unknown_tail[:64]}")

    for cat in hf.catalogs:
        live_mark = ""
        pkg = cat.package
        src = f"package@{pkg.offset:#x} uuid={pkg.database_uuid}" if pkg else "no package header"
        print(f"\n  catalog @ {cat.offset:#06x}  {cat.length:,}B  [{cat.framing}] {src}{live_mark}")
        print(f"      compression={cat.data.get('compressionMethod')}  "
              f"encryption={cat.data.get('encryptionSchemeId')}  "
              f"schemas={[n['name'] for n in cat.data.get('namespaces', [])]}")
        rels = relations(cat, hf_warn)
        if not rels:
            print("      (no relations - this is an earlier transaction's state)")
        for r in rels:
            attrs = r.get("attributes", [])
            nulls = r.get("nullCounts", [])
            print(f"      relation {qualified(r)}  oid={r.get('oid')}  "
                  f"storage={r.get('type')}  {len(attrs)} columns")
            for i, a in enumerate(attrs):
                t = "/".join(a.get("type", []))
                nc = f"  nulls={nulls[i]}" if i < len(nulls) else ""
                print(f"          {a.get('name'):<24} {t}{nc}")

    if show_blocks:
        print(f"\n  Data Block candidates ({len(hf.blocks)} found)  [HEURISTIC]")
        if not hf.blocks:
            print("      none - blocks may be stored uncompressed or use an unknown framing")
        for b in hf.blocks:
            print(f"      @{b.offset:#08x}  {b.compressed_len:>6}B -> {b.decoded_len:>7}B  "
                  f"tuples={b.tuple_count:,}")
            print(f"          header fields: {b.header_fields}")
            if b.sma_min is not None or b.sma_max is not None:
                print(f"          SMA min={b.sma_min!r}  max={b.sma_max!r}")
            if b.strings:
                print(f"          literals: {b.strings[:6]}")

    for w in hf.warnings:
        print(f"  [warn] {w}")


def verify(hf: HyperFile) -> int:
    """Cross-check against the official Hyper API, if it is installed.

    Keys on (schema, table): table names are not unique within a file.
    """
    try:
        from tableauhyperapi import HyperProcess, Connection, Telemetry
    except ImportError:
        print("  [verify] tableauhyperapi not installed - skipping oracle check")
        return 0

    ours: dict[tuple[str, str], list[str]] = {}
    for cat in hf.catalogs:
        for r in relations(cat):
            ours[(r["_schema"], r["name"])] = [a["name"] for a in r.get("attributes", [])]

    failures = 0
    seen: set[tuple[str, str]] = set()
    with HyperProcess(telemetry=Telemetry.DO_NOT_SEND_USAGE_DATA_TO_TABLEAU) as proc:
        with Connection(proc.endpoint, hf.path) as conn:
            for schema in conn.catalog.get_schema_names():
                sname = schema.name.unescaped
                for tbl in conn.catalog.get_table_names(schema):
                    tname = tbl.name.unescaped
                    key = (sname, tname)
                    seen.add(key)
                    cols = [c.name.unescaped for c in
                            conn.catalog.get_table_definition(tbl).columns]
                    if key not in ours:
                        print(f'  [verify] MISS  "{sname}"."{tname}" not found by parser')
                        failures += 1
                    elif ours[key] != cols:
                        print(f'  [verify] DIFF  "{sname}"."{tname}" '
                              f'{ours[key]} != {cols}')
                        failures += 1
                    else:
                        n = conn.execute_scalar_query(f"SELECT COUNT(*) FROM {tbl}")
                        print(f'  [verify] OK    "{sname}"."{tname}" '
                              f'{len(cols)} columns, {n:,} rows')

    for key in ours.keys() - seen:
        print(f'  [verify] EXTRA "{key[0]}"."{key[1]}" reported by parser but '
              f'not live (probably a stale transaction)')
    if not failures:
        print("  [verify] parser agrees with the Hyper API on all live relations")
    return failures


def hexdump(path: str, off: int, length: int = 256) -> None:
    d = open(path, "rb").read()
    for i in range(off, min(off + length, len(d)), 16):
        chunk = d[i:i + 16]
        text = "".join(chr(c) if 32 <= c < 127 else "." for c in chunk)
        print(f"{i:08x}  {' '.join(f'{c:02x}' for c in chunk):<47}  |{text}|")


def main() -> int:
    ap = argparse.ArgumentParser(description="Reverse-engineered Tableau .hyper reader")
    ap.add_argument("files", nargs="+")
    ap.add_argument("--blocks", action="store_true", help="hunt for Data Blocks (slow)")
    ap.add_argument("--max-blocks", type=int, default=40)
    ap.add_argument("--json", action="store_true", help="emit machine-readable output")
    ap.add_argument("--verify", action="store_true", help="cross-check against the Hyper API")
    ap.add_argument("--dump", type=lambda s: int(s, 0), help="hexdump at this offset and exit")
    args = ap.parse_args()

    if args.dump is not None:
        for p in args.files:
            print(f"--- {p} ---")
            hexdump(p, args.dump)
        return 0

    rc = 0
    for p in args.files:
        try:
            hf = parse(p, want_blocks=args.blocks, max_blocks=args.max_blocks)
        except Exception as e:                       # keep going across a batch
            print(f"{p}: FAILED: {type(e).__name__}: {e}", file=sys.stderr)
            rc = 2
            continue
        if args.json:
            print(json.dumps(asdict(hf), indent=2, default=str))
        else:
            report(hf, args.blocks)
            if args.verify:
                rc |= 1 if verify(hf) else 0
    return rc


if __name__ == "__main__":
    sys.exit(main())