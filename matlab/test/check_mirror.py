# SPDX-License-Identifier: Apache-2.0
#
# Cross-validates mirror.py against scipy.io.loadmat (the reader of record)
# on every .mat fixture in this directory. The two sides are independent:
# mirror.py parses the bytes itself; this script loads the same file through
# scipy and maps scipy's arrays through the reader's conversion contract,
# then compares structurally, cell by cell.
#
#   venv/bin/python check_mirror.py

import math
import sys
from pathlib import Path

import numpy as np
import scipy.sparse
from scipy.io import loadmat

import mirror

HERE = Path(__file__).parent


# ---- scipy output -> the reader's conversion contract -----------------------

def conv_complex(z):
    return mirror.record({"Re": float(z.real), "Im": float(z.imag)})


def conv_scalar(x):
    if isinstance(x, (np.bool_, bool)):
        return bool(x)
    if isinstance(x, (np.complexfloating, complex)):
        return conv_complex(x)
    if isinstance(x, (np.integer, int)):
        return int(x)
    return float(x)


def long_table(arr, conv):
    dims = arr.shape
    cols = ["D%d" % (i + 1) for i in range(len(dims))] + ["Value"]
    rows = []
    for idx in np.ndindex(*reversed(dims)):     # column-major order
        pos = tuple(reversed(idx))
        rows.append([i + 1 for i in pos] + [conv(arr[pos])])
    return mirror.table(cols, rows)


def conv_numeric(arr):
    if 0 in arr.shape:
        return None
    if arr.ndim > 2:
        return long_table(arr, conv_scalar)
    m, n = arr.shape
    if m == 1 and n == 1:
        return conv_scalar(arr[0, 0])
    if m == 1:
        return [conv_scalar(x) for x in arr[0, :]]
    if n == 1:
        return [conv_scalar(x) for x in arr[:, 0]]
    return mirror.table(["C%d" % (j + 1) for j in range(n)],
                        [[conv_scalar(arr[i, j]) for j in range(n)]
                         for i in range(m)])


def conv_char(arr):
    # loadmat with chars_as_strings=True collapses the last axis to strings
    if arr.size == 0:
        return ""
    if arr.ndim == 0:
        return str(arr)
    strings = [str(s) for s in arr.ravel()]
    if len(strings) == 1:
        return strings[0]
    return strings


def conv_cell(arr):
    if 0 in arr.shape:
        return None
    if arr.ndim > 2:
        return long_table(arr, conv_value)
    m, n = arr.shape
    if m == 1 and n == 1:
        return conv_value(arr[0, 0])
    if m == 1:
        return [conv_value(x) for x in arr[0, :]]
    if n == 1:
        return [conv_value(x) for x in arr[:, 0]]
    return mirror.table(["C%d" % (j + 1) for j in range(n)],
                        [[conv_value(arr[i, j]) for j in range(n)]
                         for i in range(m)])


def conv_struct(arr):
    fields = list(arr.dtype.names or [])
    if 0 in arr.shape:
        return None
    if arr.size == 1 and arr.ndim == 2:
        el = arr.reshape(-1)[0]
        return mirror.record({f: conv_value(el[f]) for f in fields})
    vector = arr.ndim == 2 and 1 in arr.shape
    if vector:
        els = arr.ravel(order="F")
        return mirror.table(fields,
                            [[conv_value(el[f]) for f in fields]
                             for el in els])
    cols = ["D%d" % (i + 1) for i in range(arr.ndim)] + fields
    rows = []
    for idx in np.ndindex(*reversed(arr.shape)):
        pos = tuple(reversed(idx))
        el = arr[pos]
        rows.append([i + 1 for i in pos] + [conv_value(el[f])
                                            for f in fields])
    return mirror.table(cols, rows)


def conv_sparse(sp):
    csc = sp.tocsc()
    csc.sort_indices()
    rows = []
    for j in range(csc.shape[1]):
        for k in range(csc.indptr[j], csc.indptr[j + 1]):
            v = csc.data[k]
            if isinstance(v, (np.bool_, bool)):
                v = bool(v)
            elif isinstance(v, (np.complexfloating, complex)):
                v = conv_complex(v)
            else:
                v = float(v)
            rows.append([int(csc.indices[k]) + 1, j + 1, v])
    return mirror.table(["Row", "Column", "Value"], rows)


def conv_value(x):
    if scipy.sparse.issparse(x):
        return conv_sparse(x)
    if isinstance(x, str):
        return x
    arr = np.asarray(x)
    if arr.dtype.names:
        return conv_struct(arr)
    if arr.dtype.kind == "U":
        return conv_char(arr)
    if arr.dtype.kind == "O":
        return conv_cell(arr)
    return conv_numeric(arr)


# ---- structural comparison --------------------------------------------------

def eq(a, b, path):
    if isinstance(a, dict) and "__table__" in a:
        if not (isinstance(b, dict) and "__table__" in b):
            return ["%s: table vs %r" % (path, type(b))]
        ta, tb = a["__table__"], b["__table__"]
        errs = []
        if ta["columns"] != tb["columns"]:
            errs.append("%s: columns %r != %r"
                        % (path, ta["columns"], tb["columns"]))
        if len(ta["rows"]) != len(tb["rows"]):
            errs.append("%s: %d rows != %d rows"
                        % (path, len(ta["rows"]), len(tb["rows"])))
        for i, (ra, rb) in enumerate(zip(ta["rows"], tb["rows"])):
            for j, (ca, cb) in enumerate(zip(ra, rb)):
                errs += eq(ca, cb, "%s[%d].%s" % (path, i,
                                                  ta["columns"][j]
                                                  if j < len(ta["columns"])
                                                  else j))
        return errs
    if isinstance(a, dict) and "__record__" in a:
        if not (isinstance(b, dict) and "__record__" in b):
            return ["%s: record vs %r" % (path, b)]
        ra, rb = a["__record__"], b["__record__"]
        if list(ra.keys()) != list(rb.keys()):
            return ["%s: fields %r != %r"
                    % (path, list(ra.keys()), list(rb.keys()))]
        errs = []
        for k in ra:
            errs += eq(ra[k], rb[k], "%s.%s" % (path, k))
        return errs
    if isinstance(a, list):
        if not isinstance(b, list) or len(a) != len(b):
            return ["%s: list mismatch %r != %r" % (path, a, b)]
        errs = []
        for i, (xa, xb) in enumerate(zip(a, b)):
            errs += eq(xa, xb, "%s[%d]" % (path, i))
        return errs
    if isinstance(a, bool) or isinstance(b, bool):
        return [] if (isinstance(a, bool) and isinstance(b, bool)
                      and a == b) else ["%s: %r != %r" % (path, a, b)]
    if isinstance(a, float) and isinstance(b, float):
        if math.isnan(a) and math.isnan(b):
            return []
        return [] if a == b else ["%s: %r != %r" % (path, a, b)]
    return [] if a == b else ["%s: %r != %r" % (path, a, b)]


def has_complex(x):
    if scipy.sparse.issparse(x):
        return x.dtype.kind == "c"
    arr = np.asarray(x)
    if arr.dtype.names:
        return any(has_complex(el[f]) for el in arr.ravel()
                   for f in arr.dtype.names)
    if arr.dtype.kind == "O":
        return any(has_complex(el) for el in arr.ravel())
    return arr.dtype.kind == "c"


def check(path):
    doc = mirror.parse(path.read_bytes())
    # mat_dtype=True: return arrays in their MATLAB class dtype, which is
    # the reader's contract (the class decides integer-ness and logical-ness,
    # not the storage type). But scipy's mat_dtype=True casts complex arrays
    # to their real class dtype, dropping the imaginary part, so complex
    # variables are taken from a second, raw load instead.
    # scipy's default uint16_codec is the system codec, which mangles
    # non-Latin-1 UTF-16 chars; it also hands the codec the raw bytes, so
    # the codec must follow the file's byte order (header bytes 126-127)
    codec = ("utf-16-be" if path.read_bytes()[126:128] == b"MI"
             else "utf-16-le")
    ref = loadmat(path, struct_as_record=True, squeeze_me=False,
                  chars_as_strings=True, mat_dtype=True,
                  uint16_codec=codec)
    raw = loadmat(path, struct_as_record=True, squeeze_me=False,
                  chars_as_strings=True, mat_dtype=False,
                  uint16_codec=codec)
    ref = {k: (raw[k] if has_complex(raw[k]) else v)
           for k, v in ref.items() if not k.startswith("__")}

    errs = []
    names = [v["name"] for v in doc["variables"]]
    if sorted(names) != sorted(ref.keys()):
        errs.append("variable names: %r != %r"
                    % (sorted(names), sorted(ref.keys())))
    for v in doc["variables"]:
        if v["name"] not in ref:
            continue
        expected = conv_value(ref[v["name"]])
        errs += eq(v["value"], expected, v["name"])
    return errs


def main():
    fixtures = sorted(HERE.glob("*.mat"))
    failed = 0
    for f in fixtures:
        try:
            errs = check(f)
        except Exception as ex:                       # noqa: BLE001
            errs = ["exception: %r" % ex]
        if errs:
            failed += 1
            print("FAIL %s" % f.name)
            for e in errs[:10]:
                print("   ", e)
        else:
            print("OK   %s" % f.name)
    print("%d/%d fixtures match" % (len(fixtures) - failed, len(fixtures)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
