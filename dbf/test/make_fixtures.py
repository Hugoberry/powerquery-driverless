# SPDX-License-Identifier: Apache-2.0
#
# Regenerates the .dbf / .dbt / .fpt fixtures in this directory.
#
#   python3 -m venv venv && venv/bin/pip install dbf dbfread
#   venv/bin/python make_fixtures.py
#
# Most fixtures are written with the `dbf` package (Ethan Furman's pure-Python
# xBase writer, the most complete open one). Two are hand-crafted byte by byte
# because no open writer produces them: a dBASE IV memo file (FF FF 08 00
# length-prefixed entries) and a Visual FoxPro 0x32 table with Varchar /
# Varbinary fields and a two-byte _NullFlags. Every fixture that dbfread can
# read is read back with dbfread after writing, so the files are confirmed
# readable by an independent reference implementation.
#
# Three deliberate byte patches, marked PATCH below:
#   - memo3.dbf: one memo pointer is blanked to 10 spaces (the "no memo yet"
#     case dBASE writes; the dbf package always allocates a block instead).
#   - fox.fpt: the picture entry's type field is set to 0 (binary); the dbf
#     package writes type 1 for everything.
#   - people.dbf: the header language-driver byte is zeroed to exercise the
#     no-declared-codepage fallback.
#
# All fixtures are synthetic; no third-party or customer data. The dbf package
# has a nondeterministic append bug (hash-order dependent), so every writer
# call is retried on DbfError until it lands; reruns differ only in the
# last-update date bytes each writer stamps into the header.

import datetime
import decimal
import glob
import os
import struct

import dbf
import dbfread

HERE = os.path.dirname(os.path.abspath(__file__))
os.chdir(HERE)


def build(name, fn):
    """The dbf package intermittently fails on append (a hash-order bug in
    update_memo); retry from scratch until the table writes cleanly."""
    for _ in range(20):
        try:
            fn()
            return
        except dbf.DbfError:
            for f in glob.glob(name + '.*'):
                os.remove(f)
    raise SystemExit('gave up writing ' + name)


def patch(path, offset, data):
    with open(path, 'r+b') as f:
        f.seek(offset)
        f.write(data)


def header(path):
    with open(path, 'rb') as f:
        b = f.read(32)
    return {'version': b[0],
            'nrec': struct.unpack('<I', b[4:8])[0],
            'hdrlen': struct.unpack('<H', b[8:10])[0],
            'reclen': struct.unpack('<H', b[10:12])[0],
            'lang': b[29]}


def report(name):
    h = header(name)
    size = os.path.getsize(name)
    print(f"{name}: version 0x{h['version']:02X}, {h['nrec']} records x "
          f"{h['reclen']} bytes, lang 0x{h['lang']:02X}, {size} bytes")


# --- people.dbf: dBASE III, every plain type, a deleted row, no codepage ---

def people():
    t = dbf.Table('people.dbf',
                  'name C(12); qty N(6,0); price N(8,2); born D; ok L',
                  dbf_type='db3')
    t.open(dbf.READ_WRITE)
    t.append(('Ada Lovelace', 42, decimal.Decimal('19.99'),
              datetime.date(1815, 12, 10), True))
    t.append(('trim  me ', -7, decimal.Decimal('-0.50'),
              datetime.date(2026, 7, 17), False))
    t.append(('', None, None, None, None))
    t.append(('deleted row', 1, decimal.Decimal('1.00'),
              datetime.date(2000, 1, 1), True))
    dbf.delete(t[3])
    t.close()

build('people', people)
patch('people.dbf', 29, b'\x00')       # PATCH: no language driver declared

# --- memo3.dbf + .dbt: dBASE III memo, multi-block, empty and blank ---

LONG_MEMO = ''.join(f'{i:04d}-abcdef ' for i in range(100))   # 1200 chars

def memo3():
    t = dbf.Table('memo3.dbf', 'title C(10); note M', dbf_type='db3')
    t.open(dbf.READ_WRITE)
    t.append(('short', 'short memo'))
    t.append(('long', LONG_MEMO))
    t.append(('empty', ''))
    t.append(('blank', ''))
    t.close()

build('memo3', memo3)
# PATCH: row 4's pointer becomes 10 spaces = field never had a memo (null),
# distinct from row 3's pointer to a zero-length entry (empty string).
h = header('memo3.dbf')
patch('memo3.dbf', h['hdrlen'] + 3 * h['reclen'] + 1 + 10, b' ' * 10)

# --- fox.dbf + .fpt: FoxPro 2.x, text memo and binary picture memo ---

PIC_BYTES = b'\x89PNG\x00\x01binary!'

def fox():
    t = dbf.Table('fox.dbf', 'name C(8); note M; pic P', dbf_type='fp')
    t.open(dbf.READ_WRITE)
    t.append(('one', 'text memo'))
    t.append(('two', ''))
    with t[0] as r:
        r.pic = PIC_BYTES
    t.close()

build('fox', fox)
# PATCH: the picture entry becomes type 0 (binary), as FoxPro writes it.
with open('fox.fpt', 'rb') as f:
    fpt = f.read()
blocksize = struct.unpack('>H', fpt[6:8])[0]
pic_block = None
i = 512
while i + 8 <= len(fpt):
    typ, length = struct.unpack('>LL', fpt[i:i + 8])
    if fpt[i + 8:i + 8 + length] == PIC_BYTES:
        pic_block = i
        break
    i += max(blocksize, -(-(8 + length) // blocksize) * blocksize)
assert pic_block is not None, 'picture entry not found in fox.fpt'
patch('fox.fpt', pic_block, struct.pack('>L', 0))

# --- vfp.dbf + .fpt: Visual FoxPro types I B Y T, null flags, memo ---

VFP_LONG_MEMO = 'v' * 500

def vfp():
    t = dbf.Table('vfp.dbf',
                  'num I; dbl B; cur Y; when T; name C(10) null; '
                  'cnt I null; ok L; note M',
                  dbf_type='vfp')
    t.open(dbf.READ_WRITE)
    t.append((7, 2.5, decimal.Decimal('12.3456'),
              datetime.datetime(2026, 7, 17, 13, 45, 30),
              'alpha', 42, True, 'vfp memo'))
    t.append((-2000000000, -0.125, decimal.Decimal('-99.99'),
              datetime.datetime(1970, 1, 1, 0, 0, 0),
              dbf.Null, dbf.Null, False, ''))
    t.append((2000000000, 1e10, decimal.Decimal('0'),
              None, '', 0, None, VFP_LONG_MEMO))
    t.close()

build('vfp', vfp)

# --- cp1251.dbf: dBASE III with a Cyrillic codepage (language driver 0xC9) ---

def cp1251():
    t = dbf.Table('cp1251.dbf', 'city C(12); pop N(8,0)',
                  dbf_type='db3', codepage='cp1251')
    t.open(dbf.READ_WRITE)
    t.append(('Москва', 13100000))
    t.append(('Київ', 2950000))
    t.append(('', None))
    t.close()

build('cp1251', cp1251)

# --- empty.dbf: a dictionary with no records ---

def empty():
    t = dbf.Table('empty.dbf', 'a C(4); b N(5,0)', dbf_type='db3')
    t.open(dbf.READ_WRITE)
    t.close()

build('empty', empty)

# --- memo4.dbf + .dbt: hand-crafted dBASE IV -----------------------------
#
# No open writer emits the dBASE IV memo layout (FF FF 08 00 signature,
# little-endian length including the 8-byte entry header). Hand-built to the
# documented layout, plus two dialect quirks worth proving: a Char field
# wider than 255 bytes (length lives in length + 256 * decimal_count) and a
# numeric that uses a comma decimal separator.

def field_descr(name, ftype, length, decimals):
    return (name.ljust(11, '\0').encode('ascii') + ftype +
            b'\x00' * 4 + bytes([length, decimals]) + b'\x00' * 14)

def db4_record(deleted, title, memo_ptr, wide, amt):
    ptr = (str(memo_ptr).rjust(10) if memo_ptr else ' ' * 10).encode('ascii')
    return ((b'*' if deleted else b' ') +
            title.ljust(10).encode('ascii') + ptr +
            wide.ljust(300).encode('ascii') + amt.rjust(8).encode('ascii'))

WIDE_TEXT = 'W' * 280
fields = (field_descr('TITLE', b'C', 10, 0) +
          field_descr('NOTE', b'M', 10, 0) +
          field_descr('WIDE', b'C', 300 - 256, 1) +    # 44 + 1*256 = 300
          field_descr('AMT', b'N', 8, 2))
hdrlen = 32 + len(fields) + 1
reclen = 1 + 10 + 10 + 300 + 8
head = struct.pack('<B3BIHH', 0x8B, 126, 7, 17, 2, hdrlen, reclen)
head = head.ljust(29, b'\x00') + b'\x00\x00\x00'      # lang 0x00 + reserved
records = (db4_record(False, 'alpha', 1, WIDE_TEXT, '123,45') +
           db4_record(False, 'beta', 0, '', '-99.99'))
with open('memo4.dbf', 'wb') as f:
    f.write(head + fields + b'\x0d' + records + b'\x1a')

DB4_MEMO = 'dbase four memo'
entry = (b'\xff\xff\x08\x00' +
         struct.pack('<L', 8 + len(DB4_MEMO)) +       # length incl. header
         DB4_MEMO.encode('ascii') + b'\x1f\x1f')
dbt_head = struct.pack('<L', 2).ljust(20, b'\x00') + struct.pack('<H', 512)
with open('memo4.dbt', 'wb') as f:
    f.write(dbt_head.ljust(512, b'\x00') + entry.ljust(512, b'\x00'))

# --- varchar.dbf: hand-crafted Visual FoxPro 0x32 ------------------------
#
# Varchar (V) and Varbinary (Q) per the VFP documentation: each V/Q field
# owns one _NullFlags bit (0 = full, 1 = actual length in the field's last
# byte); a nullable V/Q owns a second, higher bit for null; a plain nullable
# field owns one bit. Nine bits here, so _NullFlags is two bytes and row
# three exercises the second byte. No open writer supports V/Q; expected
# values live in expected.md and are asserted by check_mirror.py.

def vfp_field(name, ftype, offset, length, decimals=0, flags=0):
    return (name.ljust(11, '\0').encode('ascii') + ftype +
            struct.pack('<I', offset) + bytes([length, decimals, flags]) +
            b'\x00' * 13)

def varchar_bytes(text, size, full):
    b = text.encode('ascii') if isinstance(text, str) else text
    if full:
        assert len(b) == size
        return b
    return b + b' ' * (size - len(b) - 1) + bytes([len(b)])

NULLABLE, SYSTEM = 0x02, 0x01

# bit layout: 0 VC.len, 1 VCN.len, 2 VCN.null, 3 VB.len,
#             4..8 C1..C5.null, rest = filler ones
def vrecord(vc, vcn, vb, cs, num, bits):
    flags = 0xFFFF
    for bit, value in bits.items():
        if not value:
            flags &= ~(1 << bit)
    cbytes = b''.join((c if c is not None else '').ljust(2).encode('ascii')
                      for c in cs)
    return (b' ' + vc + vcn + vb + cbytes +
            struct.pack('<i', num) + struct.pack('<H', flags))

fields = (vfp_field('VC', b'V', 1, 10) +
          vfp_field('VCN', b'V', 11, 8, flags=NULLABLE) +
          vfp_field('VB', b'Q', 19, 6, flags=0x04) +
          vfp_field('C1', b'C', 25, 2, flags=NULLABLE) +
          vfp_field('C2', b'C', 27, 2, flags=NULLABLE) +
          vfp_field('C3', b'C', 29, 2, flags=NULLABLE) +
          vfp_field('C4', b'C', 31, 2, flags=NULLABLE) +
          vfp_field('C5', b'C', 33, 2, flags=NULLABLE) +
          vfp_field('NUM', b'I', 35, 4) +
          vfp_field('_NullFlags', b'0', 39, 2, flags=SYSTEM | 0x04))
hdrlen = 32 + len(fields) + 1 + 263                   # VFP backlink
reclen = 1 + 10 + 8 + 6 + 10 + 4 + 2
head = struct.pack('<B3BIHH', 0x32, 126, 7, 17, 3, hdrlen, reclen)
head = head.ljust(29, b'\x00') + b'\x03\x00\x00'      # lang 0x03 = cp1252
rows = (
    vrecord(varchar_bytes('ABCDEFGHIJ', 10, True),
            varchar_bytes('xy', 8, False),
            varchar_bytes(b'\x01\x02\x03\x04\x05\x06', 6, True),
            ['aa', None, 'cc', '', 'ee'], 1,
            {0: 0, 1: 1, 2: 0, 3: 0, 4: 0, 5: 1, 6: 0, 7: 0, 8: 0}) +
    vrecord(varchar_bytes('AB', 10, False),
            varchar_bytes('', 8, False),
            varchar_bytes(b'\x01\x02', 6, False),
            [None, 'bb', None, 'dd', None], -5,
            {0: 1, 1: 1, 2: 1, 3: 1, 4: 1, 5: 0, 6: 1, 7: 0, 8: 1}) +
    vrecord(varchar_bytes('', 10, False),
            varchar_bytes('FULLFULL', 8, True),
            varchar_bytes(b'', 6, False),
            ['zz', '', '', '', ''], 0,
            {0: 1, 1: 0, 2: 0, 3: 1, 4: 0, 5: 0, 6: 0, 7: 0, 8: 0}))
with open('varchar.dbf', 'wb') as f:
    f.write(head + fields + b'\x0d' + b'\x00' * 263 + rows + b'\x1a')

# --- report and verify with dbfread where it can read the file -----------

print()
for name in ('people.dbf', 'memo3.dbf', 'fox.dbf', 'vfp.dbf',
             'cp1251.dbf', 'empty.dbf', 'memo4.dbf', 'varchar.dbf'):
    report(name)

print()
for name in ('people.dbf', 'memo3.dbf', 'fox.dbf', 'vfp.dbf',
             'cp1251.dbf', 'empty.dbf', 'memo4.dbf'):
    table = dbfread.DBF(name, load=True)
    print(f"dbfread {name}: {len(table.records)} records, "
          f"{len(table.deleted)} deleted, fields "
          f"{[f.name for f in table.fields]}")
