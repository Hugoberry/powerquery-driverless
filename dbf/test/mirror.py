# SPDX-License-Identifier: Apache-2.0
#
# Pure-Python mirror of the parse logic destined for Dbf.Table.pq. Every
# decision here (offsets, type decoding, null-flag bits, memo lookup) is
# meant to translate 1:1 into M; keep the two in sync. Validated against
# dbfread and hand-written expected values by check_mirror.py.

import datetime
import struct

# Version byte -> dialect. Memo style and double-vs-memo interpretation of
# type B both key off this.
FOXPRO_VERSIONS = {0x30, 0x31, 0x32, 0xF5}          # .fpt sidecar
DBASE3_MEMO_VERSIONS = {0x02, 0x83, 0xFB}           # .dbt, 0x1A-terminated
DBASE4_MEMO_VERSIONS = {0x8B, 0x8E, 0xCB}           # .dbt, length-prefixed
KNOWN_VERSIONS = ({0x02, 0x03, 0x43, 0x63, 0x83, 0x8B, 0x8E, 0xCB, 0xFB}
                  | FOXPRO_VERSIONS)
DBASE7_VERSIONS = {0x04, 0x8C}

VFP_VERSIONS = {0x30, 0x31, 0x32}                   # B = double, 4-byte memo ptr

# Language driver byte -> codepage, per the xBase language driver table.
CODEPAGES = {
    0x01: 437, 0x02: 850, 0x03: 1252, 0x04: 10000, 0x08: 865, 0x09: 437,
    0x0A: 850, 0x0B: 437, 0x0D: 437, 0x0E: 850, 0x0F: 437, 0x10: 850,
    0x11: 437, 0x12: 850, 0x13: 932, 0x14: 850, 0x15: 437, 0x16: 850,
    0x17: 865, 0x18: 437, 0x19: 437, 0x1A: 850, 0x1B: 437, 0x1C: 863,
    0x1D: 850, 0x1F: 852, 0x22: 852, 0x23: 852, 0x24: 860, 0x25: 850,
    0x26: 866, 0x37: 850, 0x40: 852, 0x4D: 936, 0x4E: 949, 0x4F: 950,
    0x50: 874, 0x57: 1252, 0x58: 1252, 0x59: 1252, 0x64: 852, 0x65: 866,
    0x66: 865, 0x67: 861, 0x6A: 737, 0x6B: 857, 0x6C: 863, 0x78: 950,
    0x79: 949, 0x7A: 936, 0x7B: 932, 0x7C: 874, 0x7D: 1255, 0x7E: 1256,
    0x86: 737, 0x87: 852, 0x88: 857, 0xC8: 1250, 0xC9: 1251, 0xCA: 1254,
    0xCB: 1253, 0xCC: 1257,
}
DEFAULT_CODEPAGE = 1252

SYSTEM, NULLABLE, BINARY = 0x01, 0x02, 0x04

JULIAN_OFFSET = 1721425     # Julian day number -> proleptic Gregorian ordinal


class DbfError(Exception):
    pass


def decode(b, codepage):
    enc = 'mac_roman' if codepage == 10000 else 'cp%d' % codepage
    return b.decode(enc, errors='replace')


def parse(data, memo=None, encoding=None, include_deleted=False,
          strict=False, max_rows=None):
    total = len(data)
    if total < 32:
        raise DbfError('file shorter than the 32-byte header')

    version = data[0]
    if version in DBASE7_VERSIONS:
        raise DbfError('dBASE Level 7 files use a different header layout '
                       'and are not supported')
    if version not in KNOWN_VERSIONS:
        raise DbfError('not a dBASE/FoxPro table (version byte 0x%02X)'
                       % version)

    nrec = struct.unpack('<I', data[4:8])[0]
    hdrlen = struct.unpack('<H', data[8:10])[0]
    reclen = struct.unpack('<H', data[10:12])[0]
    lang = data[29]
    codepage = encoding or CODEPAGES.get(lang, DEFAULT_CODEPAGE)

    if hdrlen < 65 or hdrlen > total or reclen < 1:
        raise DbfError('header sizes are implausible '
                       '(header %d, record %d, file %d)'
                       % (hdrlen, reclen, total))

    # --- field descriptor array: 32 bytes each, 0x0D terminator ---
    fields = []
    off = 32
    while off + 1 <= total and data[off] not in (0x0D,):
        if off + 32 > total or off + 32 > hdrlen:
            raise DbfError('field descriptor array has no 0x0D terminator')
        d = data[off:off + 32]
        name = d[:11].split(b'\0')[0]
        ftype = chr(d[11])
        length = d[16]
        decimals = d[17]
        flags = d[18]
        if ftype == 'C' and decimals > 0:           # wide-char dialect trick
            length += decimals * 256
            decimals = 0
        fields.append({'name': decode(name, codepage), 'type': ftype,
                       'length': length, 'decimals': decimals,
                       'flags': flags})
        off += 32

    # --- record offsets (cumulative; byte 0 is the deletion flag) ---
    pos = 1
    for f in fields:
        f['offset'] = pos
        pos += f['length']
    if pos != reclen and strict:
        raise DbfError('field lengths sum to %d but the header says the '
                       'record is %d bytes' % (pos, reclen))

    # --- null / varlength bits, allocated in field order ---
    # V/Q first take a varlength bit (0 = full, 1 = actual length in the
    # field's last byte); a NULLABLE field then takes a null bit.
    bit = 0
    for f in fields:
        f['varlen_bit'] = f['null_bit'] = None
        if f['type'] in 'VQ':
            f['varlen_bit'] = bit
            bit += 1
        if f['flags'] & NULLABLE:
            f['null_bit'] = bit
            bit += 1
    nullflags = next((f for f in fields
                      if f['type'] == '0' or f['name'].upper() == '_NULLFLAGS'),
                     None)

    visible = [f for f in fields
               if f['type'] != '0' and not f['flags'] & SYSTEM]

    # --- memo sidecar ---
    fpt = version in FOXPRO_VERSIONS
    db4 = version in DBASE4_MEMO_VERSIONS
    memo_block = 512
    if memo is not None and fpt:
        if len(memo) < 8:
            raise DbfError('memo file shorter than its 8-byte header')
        memo_block = struct.unpack('>H', memo[6:8])[0]
        if memo_block == 0:
            raise DbfError('memo file declares block size 0')

    def memo_lookup(ptr, want_text):
        # Returns text or bytes; None for a blank pointer.
        if ptr is None or ptr <= 0:
            return None
        if memo is None:
            if strict:
                raise DbfError('record points into a memo file, but no memo '
                               'sidecar was provided')
            return None
        start = ptr * memo_block
        if fpt:
            if start + 8 > len(memo):
                raise DbfError('memo pointer %d is beyond the memo file' % ptr)
            typ, length = struct.unpack('>LL', memo[start:start + 8])
            raw = memo[start + 8:start + 8 + length]
            if len(raw) < length:
                raise DbfError('memo entry %d is truncated' % ptr)
            if typ == 1 and want_text:
                return decode(raw, codepage)
            return raw
        if db4 and memo[start:start + 4] == b'\xff\xff\x08\x00':
            length = struct.unpack('<L', memo[start + 4:start + 8])[0]
            raw = memo[start + 8:start + length]
        else:                                       # dBASE III: scan for 0x1A
            end = memo.find(b'\x1a', start)
            raw = memo[start:end if end != -1 else len(memo)]
        if want_text:
            return decode(raw, codepage).rstrip('\x1a\x1f')
        return raw

    # --- one field of one record ---
    def cell(f, rec):
        raw = rec[f['offset']:f['offset'] + f['length']]
        t = f['type']
        if t in 'VQ' and f['varlen_bit'] is not None:
            nf = rec[nullflags['offset']:
                     nullflags['offset'] + nullflags['length']] \
                 if nullflags else b''
            b, r = divmod(f['varlen_bit'], 8)
            if b < len(nf) and nf[b] >> r & 1:
                raw = raw[:raw[-1]]
        if t in ('C', 'V'):
            text = decode(raw, codepage)
            return text.rstrip(' \x00') if t == 'C' else text
        if t == 'Q':
            return raw
        if t in ('N', 'F'):
            text = decode(raw, 1252).strip(' \x00*').replace(',', '.')
            if text in ('', '.'):
                return None
            try:
                return int(text) if f['decimals'] == 0 and t == 'N' \
                    and '.' not in text else float(text)
            except ValueError:
                if strict:
                    raise DbfError('bad numeric %r in field %s'
                                   % (text, f['name']))
                return None
        if t == 'D':
            text = decode(raw, 1252)
            if text.strip(' 0\x00') == '':
                return None
            try:
                return datetime.date(int(text[:4]), int(text[4:6]),
                                     int(text[6:8]))
            except ValueError:
                if strict:
                    raise DbfError('bad date %r in field %s'
                                   % (text, f['name']))
                return None
        if t == 'L':
            c = decode(raw, 1252)
            if c in 'TtYy':
                return True
            if c in 'FfNn':
                return False
            if strict and c not in '? \x00':
                raise DbfError('bad logical %r in field %s' % (c, f['name']))
            return None
        if t in ('I', '+'):
            return struct.unpack('<i', raw)[0]
        if t == 'B' and version in VFP_VERSIONS:
            return struct.unpack('<d', raw)[0]
        if t == 'Y':
            return struct.unpack('<q', raw)[0] / 10000
        if t == 'T':
            if raw.strip(b' \x00') == b'':
                return None
            day, msec = struct.unpack('<LL', raw)
            if day == 0:
                return None
            return (datetime.datetime.fromordinal(day - JULIAN_OFFSET)
                    + datetime.timedelta(milliseconds=msec))
        if t in ('M', 'G', 'P', 'B', 'W'):
            if f['length'] == 4:
                ptr = struct.unpack('<i', raw)[0]
            else:
                text = decode(raw, 1252).strip(' \x00')
                ptr = int(text) if text else 0
            want_text = t == 'M' and not f['flags'] & BINARY
            return memo_lookup(ptr, want_text)
        raise DbfError('unsupported field type %r (field %s)'
                       % (t, f['name']))

    def null_of(f, rec):
        if f['null_bit'] is None or nullflags is None:
            return False
        nf = rec[nullflags['offset']:
                 nullflags['offset'] + nullflags['length']]
        b, r = divmod(f['null_bit'], 8)
        return b < len(nf) and bool(nf[b] >> r & 1)

    # --- records ---
    avail = (total - hdrlen) // reclen if reclen else 0
    if avail < nrec:
        if strict:
            raise DbfError('header declares %d records but only %d fit in '
                           'the file' % (nrec, avail))
        nrec = avail

    rows, deleted = [], []
    for i in range(nrec):
        rec = data[hdrlen + i * reclen:hdrlen + (i + 1) * reclen]
        flag = rec[0]
        if flag == 0x1A:
            break
        is_deleted = flag == 0x2A
        if is_deleted and not include_deleted:
            continue
        rows.append([None if null_of(f, rec) else cell(f, rec)
                     for f in visible])
        deleted.append(is_deleted)
        if max_rows is not None and len(rows) >= max_rows:
            break

    yy, mm, dd = data[1], data[2], data[3]
    return {
        'version': version,
        'codepage': codepage,
        'language_driver': lang,
        'last_update': (1900 + yy, mm, dd),
        'record_count': struct.unpack('<I', data[4:8])[0],
        'fields': visible,
        'all_fields': fields,
        'rows': rows,
        'deleted': deleted,
    }
