# SPDX-License-Identifier: Apache-2.0
#
# Cross-validates mirror.py (the byte-level parse logic destined for
# Spss.Document.pq) against pyreadstat (ReadStat, the reference
# implementation) on every fixture in this directory: cell-by-cell data
# comparison plus dictionary metadata (labels, formats, missing specs,
# measures, value labels, encoding).
#
#   venv/bin/python check_mirror.py

import datetime
import math

import pandas as pd
from pathlib import Path

import pyreadstat

from mirror import parse, fmt_text, DATE_FORMATS, DATETIME_FORMATS, TIME_FORMATS

HERE = Path(__file__).parent
EPOCH = datetime.datetime(1582, 10, 14)

FIXTURES = ["types.sav", "rowcomp.sav", "types.zsav", "labels.sav",
            "dates.sav", "longstr.sav", "empty.sav", "legacy1252.sav",
            "multiblock.zsav"]

failures = []


def note(fixture, msg):
    failures.append(f"{fixture}: {msg}")
    print(f"  FAIL {msg}")


def convert(value, print_fmt):
    """Apply the same date/time conversion the M reader will apply."""
    if value is None or not isinstance(value, float):
        return value
    ftype = (print_fmt >> 16) & 0xFF
    if ftype in DATE_FORMATS:
        return (EPOCH + datetime.timedelta(seconds=value)).date()
    if ftype in DATETIME_FORMATS:
        return EPOCH + datetime.timedelta(seconds=value)
    if ftype in TIME_FORMATS:
        return datetime.timedelta(seconds=value)
    return value


def eq(a, b):
    if a is None and b is None:
        return True
    if isinstance(a, float) and isinstance(b, float):
        if math.isnan(a) and math.isnan(b):
            return True
        return a == b
    if isinstance(a, datetime.timedelta) and isinstance(b, datetime.time):
        return (datetime.datetime.min + a).time() == b
    return a == b


def ref_cell(v):
    if v is None or (not isinstance(v, str) and pd.isna(v)):
        return None
    return v


for fixture in FIXTURES:
    print(f"{fixture}")
    data = (HERE / fixture).read_bytes()
    m = parse(data)
    ref, meta = pyreadstat.read_sav(str(HERE / fixture), user_missing=True)

    # column names (long names applied, VLS segments merged)
    names = [v["name"] for v in m["variables"]]
    if names != list(meta.column_names):
        note(fixture, f"column names {names} != {list(meta.column_names)}")
        continue

    # row count
    if len(m["rows"]) != len(ref):
        note(fixture, f"row count {len(m['rows'])} != {len(ref)}")
        continue

    # cells
    bad = 0
    for r, row in enumerate(m["rows"]):
        for c, v in enumerate(m["variables"]):
            mine = convert(row[c], v["print_fmt"])
            theirs = ref_cell(ref.iloc[r, c])
            if isinstance(theirs, float) and isinstance(mine, datetime.timedelta):
                theirs = datetime.timedelta(seconds=theirs)  # pyreadstat TIME as seconds
            if not eq(mine, theirs):
                bad += 1
                if bad <= 5:
                    note(fixture, f"cell [{r},{names[c]}]: {mine!r} != {theirs!r}")
    if bad:
        note(fixture, f"{bad} cell mismatches total")

    # variable labels
    for v, reflab in zip(m["variables"], meta.column_labels):
        lab = v["label"]
        if (lab or None) != (reflab or None):
            note(fixture, f"label of {v['name']}: {lab!r} != {reflab!r}")

    # formats
    for v, reffmt in zip(m["variables"], meta.original_variable_types.values()):
        got = fmt_text(v["print_fmt"], v["width"] if v["width"] > 0 else None)
        if got != reffmt:
            note(fixture, f"format of {v['name']}: {got!r} != {reffmt!r}")

    # value labels
    mine_vl = {(n, val): lab for n, val, lab in m["value_labels"]}
    ref_vl = {}
    for var, mapping in (meta.variable_value_labels or {}).items():
        for val, lab in mapping.items():
            ref_vl[(var, val)] = lab
    if mine_vl != ref_vl:
        note(fixture, f"value labels {mine_vl} != {ref_vl}")

    # missing specs
    ref_missing = meta.missing_ranges or {}
    for v in m["variables"]:
        refm = ref_missing.get(v["name"])
        if v["missing"] is None:
            if refm:
                note(fixture, f"missing spec absent for {v['name']}, ref {refm}")
            continue
        got = []
        if "lo" in v["missing"]:
            got.append({"lo": v["missing"]["lo"], "hi": v["missing"]["hi"]})
            got += [{"lo": x, "hi": x} for x in v["missing"]["values"]]
        else:
            got = [{"lo": x, "hi": x} for x in v["missing"]["values"]]
        if got != refm:
            note(fixture, f"missing spec of {v['name']}: {got} != {refm}")

    # measure / display width
    if meta.variable_measure:
        for v in m["variables"]:
            refmeas = meta.variable_measure.get(v["name"])
            mine = (v.get("measure") or "unknown").lower()
            if refmeas and refmeas != "unknown" and mine != refmeas:
                note(fixture, f"measure of {v['name']}: {mine} != {refmeas}")

    # encoding + file label
    if meta.file_encoding:
        norm = {"cp1252": "WINDOWS-1252", "utf-8": "UTF-8"}
        if norm.get(m["encoding"], m["encoding"]).upper() != meta.file_encoding.upper():
            note(fixture, f"encoding {m['encoding']} != {meta.file_encoding}")
    if (m["file_label"] or "") != (meta.file_label or ""):
        note(fixture, f"file label {m['file_label']!r} != {meta.file_label!r}")

    if not any(f.startswith(fixture) for f in failures):
        print(f"  OK   {len(m['rows'])} rows x {len(names)} cols, "
              f"{len(mine_vl)} value labels, encoding {m['encoding']}")

print()
if failures:
    print(f"{len(failures)} FAILURES")
    raise SystemExit(1)
print(f"all {len(FIXTURES)} fixtures match pyreadstat")
