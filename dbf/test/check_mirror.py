# SPDX-License-Identifier: Apache-2.0
#
# Cross-validates mirror.py (the byte-level parse logic destined for
# Dbf.Table.pq) two ways on every fixture in this directory:
#
#   1. cell-by-cell against dbfread, an independent reference reader,
#      except cells dbfread is known to get wrong (it ignores VFP null
#      flags and parses Varchar as if it were Char);
#   2. against hand-written expected literals, so the intended output is
#      pinned even where dbfread cannot arbitrate.
#
#   venv/bin/python check_mirror.py

import datetime
import decimal
from pathlib import Path

import dbfread

from mirror import parse

HERE = Path(__file__).parent

LONG_MEMO = ''.join(f'{i:04d}-abcdef ' for i in range(100))
PIC_BYTES = b'\x89PNG\x00\x01binary!'

# fixture -> (memo sidecar, expected column names, expected active rows,
#             expected deleted rows, cells dbfread reads differently
#             {(row, col): dbfread value}, columns to skip in the dbfread
#             comparison)
FIXTURES = {
    'people.dbf': dict(
        memo=None,
        columns=['NAME', 'QTY', 'PRICE', 'BORN', 'OK'],
        rows=[
            ['Ada Lovelace', 42, 19.99, datetime.date(1815, 12, 10), True],
            ['trim  me', -7, -0.5, datetime.date(2026, 7, 17), False],
            ['', None, None, None, None],
        ],
        deleted_rows=[
            ['deleted row', 1, 1.0, datetime.date(2000, 1, 1), True],
        ],
    ),
    'memo3.dbf': dict(
        memo='memo3.dbt',
        columns=['TITLE', 'NOTE'],
        rows=[
            ['short', 'short memo'],
            ['long', LONG_MEMO],
            ['empty', ''],
            ['blank', None],
        ],
        deleted_rows=[],
    ),
    'fox.dbf': dict(
        memo='fox.fpt',
        columns=['NAME', 'NOTE', 'PIC'],
        rows=[
            ['one', 'text memo', PIC_BYTES],
            ['two', '', None],
        ],
        deleted_rows=[],
    ),
    'vfp.dbf': dict(
        memo='vfp.fpt',
        columns=['NUM', 'DBL', 'CUR', 'WHEN', 'NAME', 'CNT', 'OK', 'NOTE'],
        rows=[
            [7, 2.5, 12.3456, datetime.datetime(2026, 7, 17, 13, 45, 30),
             'alpha', 42, True, 'vfp memo'],
            [-2000000000, -0.125, -99.99, datetime.datetime(1970, 1, 1),
             None, None, False, ''],
            [2000000000, 1e10, 0.0, None, '', 0, None, 'v' * 500],
        ],
        deleted_rows=[],
        # dbfread ignores _NullFlags: null cells come back as blank values
        dbfread_diffs={(1, 'NAME'): '', (1, 'CNT'): 0},
    ),
    'cp1251.dbf': dict(
        memo=None,
        columns=['CITY', 'POP'],
        rows=[
            ['Москва', 13100000],
            ['Київ', 2950000],
            ['', None],
        ],
        deleted_rows=[],
    ),
    'empty.dbf': dict(
        memo=None,
        columns=['A', 'B'],
        rows=[],
        deleted_rows=[],
    ),
    'memo4.dbf': dict(
        memo='memo4.dbt',
        columns=['TITLE', 'NOTE', 'WIDE', 'AMT'],
        rows=[
            ['alpha', 'dbase four memo', 'W' * 280, 123.45],
            ['beta', None, '', -99.99],
        ],
        deleted_rows=[],
    ),
    'varchar.dbf': dict(
        memo=None,
        columns=['VC', 'VCN', 'VB', 'C1', 'C2', 'C3', 'C4', 'C5', 'NUM'],
        rows=[
            ['ABCDEFGHIJ', 'xy', b'\x01\x02\x03\x04\x05\x06',
             'aa', None, 'cc', '', 'ee', 1],
            ['AB', None, b'\x01\x02', None, 'bb', None, 'dd', None, -5],
            ['', 'FULLFULL', b'', 'zz', '', '', '', '', 0],
        ],
        deleted_rows=[],
        # dbfread refuses type Q outright, parses V as if it were C and
        # ignores null flags; the expected literals above are the check.
        no_dbfread=True,
    ),
}

failures = []


def note(fixture, msg):
    failures.append(f'{fixture}: {msg}')
    print(f'  FAIL {msg}')


def eq(mine, theirs):
    if isinstance(theirs, decimal.Decimal) and isinstance(mine, float):
        return float(theirs) == mine
    if isinstance(theirs, float) and isinstance(mine, int):
        return theirs == float(mine)
    if isinstance(theirs, bytes) and isinstance(mine, bytes):
        return bytes(theirs) == bytes(mine)
    return mine == theirs


for fixture, spec in FIXTURES.items():
    print(fixture)
    data = (HERE / fixture).read_bytes()
    memo = (HERE / spec['memo']).read_bytes() if spec['memo'] else None
    m = parse(data, memo=memo, include_deleted=True)

    names = [f['name'] for f in m['fields']]
    if names != spec['columns']:
        note(fixture, f"columns {names} != {spec['columns']}")
        continue

    active = [r for r, d in zip(m['rows'], m['deleted']) if not d]
    dropped = [r for r, d in zip(m['rows'], m['deleted']) if d]

    # --- hand-written expectations ---
    for label, got, want in (('active', active, spec['rows']),
                             ('deleted', dropped, spec['deleted_rows'])):
        if len(got) != len(want):
            note(fixture, f'{label} row count {len(got)} != {len(want)}')
            continue
        for r, (grow, wrow) in enumerate(zip(got, want)):
            for c, (gv, wv) in enumerate(zip(grow, wrow)):
                if not eq(gv, wv):
                    note(fixture, f'expected[{label} {r},{names[c]}]: '
                                  f'{gv!r} != {wv!r}')

    # --- independent reference: dbfread ---
    if not spec.get('no_dbfread'):
        skip = set(spec.get('dbfread_skip', []))
        diffs = spec.get('dbfread_diffs', {})
        ref = dbfread.DBF(str(HERE / fixture), load=True)
        if len(ref.records) != len(active):
            note(fixture, f'dbfread row count {len(ref.records)} != '
                          f'{len(active)}')
            continue
        for r, (mrow, rrow) in enumerate(zip(active, ref.records)):
            for c, name in enumerate(names):
                if name in skip:
                    continue
                mine = mrow[c]
                theirs = rrow[name]
                if (r, name) in diffs:
                    if not eq(diffs[(r, name)], theirs):
                        note(fixture, f'dbfread[{r},{name}]: expected '
                                      f'dbfread to read {diffs[(r, name)]!r},'
                                      f' got {theirs!r}')
                    continue
                if not eq(mine, theirs):
                    note(fixture, f'dbfread[{r},{name}]: {mine!r} != '
                                  f'{theirs!r}')
        for r, (mrow, rrow) in enumerate(zip(dropped, ref.deleted)):
            for c, name in enumerate(names):
                if name in skip or (r, name) in diffs:
                    continue
                if not eq(mrow[c], rrow[name]):
                    note(fixture, f'dbfread deleted[{r},{name}]: '
                                  f'{mrow[c]!r} != {rrow[name]!r}')

    if not any(f.startswith(fixture) for f in failures):
        print(f'  OK   {len(active)} rows (+{len(dropped)} deleted) x '
              f'{len(names)} cols, codepage cp{m["codepage"]}')

print()
if failures:
    print(f'{len(failures)} FAILURES')
    raise SystemExit(1)
print(f'all {len(FIXTURES)} fixtures match dbfread and the expected values')
