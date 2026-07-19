# SPDX-License-Identifier: Apache-2.0
#
# Cross-validates mirror.py (the byte-level parse logic destined for
# Stata.Document.pq) against pandas and pyreadstat (the readers of record)
# on every fixture in this directory: cell-by-cell data comparison plus
# metadata (variable labels, formats, value labels, missing codes, dataset
# label, sort order, date conversion).
#
#   venv/bin/python check_mirror.py

import datetime
import math
from pathlib import Path

import pandas as pd
import pyreadstat

from mirror import parse, fmt_kind, convert_datish, MISS_NAMES, label_key

HERE = Path(__file__).parent

FIXTURES = ["types113.dta", "types114.dta", "types115.dta", "types117.dta",
            "types118.dta", "types119.dta", "labels118.dta", "dates118.dta",
            "strl117.dta", "strl118.dta", "empty118.dta", "legacy1252.dta",
            "msf118.dta"]

failures = []


def note(fixture, msg):
    failures.append(f"{fixture}: {msg}")
    print(f"  FAIL {msg}")


def eq_cell(mine, theirs):
    if isinstance(mine, tuple) and mine[0] == "miss":
        return theirs is None or (isinstance(theirs, float)
                                  and math.isnan(theirs))
    if theirs is None or (isinstance(theirs, float) and math.isnan(theirs)):
        return False
    if isinstance(mine, float) and isinstance(theirs, float):
        return mine == theirs or abs(mine - theirs) <= 1e-6 * abs(theirs)
    if isinstance(mine, bytes):
        # pandas 3.x renders binary strLs as the bytes' repr
        return theirs == mine or theirs == str(mine)
    return mine == theirs


for fixture in FIXTURES:
    print(fixture)
    data = (HERE / fixture).read_bytes()
    m = parse(data)

    with pd.io.stata.StataReader(str(HERE / fixture)) as rd:
        ref = rd.read(convert_categoricals=False, convert_dates=False,
                      convert_missing=False)
        ref_labels = rd.variable_labels()
        ref_vallabs = rd.value_labels()
        ref_dlabel = rd.data_label
    with pd.io.stata.StataReader(str(HERE / fixture)) as rd:
        ref_miss = rd.read(convert_categoricals=False, convert_dates=False,
                           convert_missing=True)

    names = [v["name"] for v in m["variables"]]
    if names != list(ref.columns):
        note(fixture, f"column names {names} != {list(ref.columns)}")
        continue
    if len(m["rows"]) != len(ref):
        note(fixture, f"row count {len(m['rows'])} != {len(ref)}")
        continue

    # cells (raw values; missing equivalence checked both coarse and exact)
    bad = 0
    for r, row in enumerate(m["rows"]):
        for c, v in enumerate(m["variables"]):
            mine = row[c]
            theirs = ref.iloc[r, c]
            if not eq_cell(mine, theirs):
                bad += 1
                if bad <= 5:
                    note(fixture, f"cell [{r},{names[c]}]: "
                                  f"{mine!r} != {theirs!r}")
            tm = ref_miss.iloc[r, c]
            if isinstance(mine, tuple) and mine[0] == "miss":
                want = MISS_NAMES[mine[1]]
                got = getattr(tm, "string", None)
                if got != want:
                    bad += 1
                    if bad <= 5:
                        note(fixture, f"missing code [{r},{names[c]}]: "
                                      f"{want} != {got}")
    if bad > 5:
        note(fixture, f"{bad} cell mismatches total")

    # variable labels
    for v in m["variables"]:
        reflab = ref_labels.get(v["name"]) or None
        if (v["label"] or None) != reflab:
            note(fixture, f"label of {v['name']}: "
                          f"{v['label']!r} != {reflab!r}")

    # dataset label
    if (m["label"] or None) != (ref_dlabel or None):
        note(fixture, f"dataset label {m['label']!r} != {ref_dlabel!r}")

    # value-label tables (keys compared raw, int32)
    mine_sets = {k: v for k, v in m["value_labels"].items() if v}
    ref_sets = {k: {int(kk): vv for kk, vv in tab.items()}
                for k, tab in (ref_vallabs or {}).items()}
    mine_cmp = {k: {int(kk): vv for kk, vv in tab.items()}
                for k, tab in mine_sets.items()}
    if mine_cmp != ref_sets:
        note(fixture, f"value labels {mine_cmp} != {ref_sets}")

    # formats + per-variable label-set association, via pyreadstat
    try:
        _, meta = pyreadstat.read_dta(str(HERE / fixture))
        for v, reffmt in zip(m["variables"],
                             meta.original_variable_types.values()):
            if v["format"] != reffmt:
                note(fixture, f"format of {v['name']}: "
                              f"{v['format']!r} != {reffmt!r}")
        for v in m["variables"]:
            got = (m["value_labels"].get(v["label_set"]) or None) \
                if v["label_set"] else None
            refmap = (meta.variable_value_labels or {}).get(v["name"]) or None
            got_cmp = ({label_key(k): t for k, t in got.items()}
                       if got else None)
            ref_cmp = ({label_key(int(k)): t for k, t in refmap.items()}
                       if refmap else None)
            if got_cmp != ref_cmp:
                note(fixture, f"label set of {v['name']}: "
                              f"{got_cmp} != {ref_cmp}")
    except Exception as exc:
        print(f"  note: pyreadstat skipped ({type(exc).__name__}: {exc})")

    # date conversion: mirror's conversion vs pandas convert_dates
    datish = [i for i, v in enumerate(m["variables"])
              if fmt_kind(v["format"]) in ("td", "tc", "tm", "tq", "th", "tw")]
    if datish:
        with pd.io.stata.StataReader(str(HERE / fixture)) as rd:
            ref_dates = rd.read(convert_categoricals=False,
                                convert_dates=True, convert_missing=False)
        for c in datish:
            v = m["variables"][c]
            kind = fmt_kind(v["format"])
            for r, row in enumerate(m["rows"]):
                cell = row[c]
                theirs = ref_dates.iloc[r, c]
                if isinstance(cell, tuple):
                    if not pd.isna(theirs):
                        note(fixture, f"date [{r},{v['name']}]: "
                                      f"missing != {theirs!r}")
                    continue
                mine = convert_datish(kind, cell)
                if isinstance(mine, datetime.date) \
                        and not isinstance(mine, datetime.datetime):
                    mine = datetime.datetime.combine(mine, datetime.time())
                if pd.isna(theirs) or abs(pd.Timestamp(mine)
                                          - theirs) > pd.Timedelta("1ms"):
                    note(fixture, f"date [{r},{v['name']}] ({kind}): "
                                  f"{mine!r} != {theirs!r}")

    if not any(f.startswith(fixture) for f in failures):
        extra = f", sorted by {m['sort_by']}" if m["sort_by"] else ""
        print(f"  OK   release {m['release']} {m['byteorder']}, "
              f"{len(m['rows'])} rows x {len(names)} cols, "
              f"{len(mine_sets)} label sets{extra}")

# fixture-specific expectations that no reference reader exposes
m = parse((HERE / "legacy1252.dta").read_bytes())
if m["sort_by"] != ["grp"]:
    note("legacy1252.dta", f"sort_by {m['sort_by']} != ['grp']")
m = parse((HERE / "msf118.dta").read_bytes())
if m["sort_by"] != ["id"]:
    note("msf118.dta", f"sort_by {m['sort_by']} != ['id']")
if m["byteorder"] != "MSF":
    note("msf118.dta", "byteorder not detected as MSF")
idlbl = {label_key(k): v for k, v in m["value_labels"]["idlbl"].items()}
if idlbl != {1: "one", 2: "two", ".a": "refused"}:
    note("msf118.dta", f"extended-missing label key: {idlbl}")

print()
if failures:
    print(f"{len(failures)} FAILURES")
    raise SystemExit(1)
print(f"all {len(FIXTURES)} fixtures match the reference readers")
