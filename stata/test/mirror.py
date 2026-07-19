# SPDX-License-Identifier: Apache-2.0
#
# Pure-Python mirror of the parse logic destined for Stata.Document.pq.
# Byte-level only — no pandas, no pyreadstat. Every algorithmic decision in
# the M reader is prototyped here first, then this mirror is cross-validated
# cell-by-cell against pandas / pyreadstat (readers of record) by
# check_mirror.py.
#
# Structure intentionally parallels the M reader:
#   parse(data) -> {release, byteorder, nvar, nobs, label, timestamp,
#                   variables, value_labels, sort_by, rows}
#
# Supported releases: 113, 114, 115 (legacy raw container) and 117, 118,
# 119 (tag-delimited container). Both byte orders. Formats 102-112 and the
# alias formats 120/121 raise clear errors.

import datetime
import struct

# --- per-release layout parameters (from the published StataCorp specs) ---------
# varname / format / lblname / varlabel are fixed field widths; vo_v is the
# byte width of v in a (v,o) strL pointer in <data> (o takes the rest of 8).
LAYOUT = {
    113: dict(varname=33, fmt=12, lblname=33, varlabel=81),
    114: dict(varname=33, fmt=49, lblname=33, varlabel=81),
    115: dict(varname=33, fmt=49, lblname=33, varlabel=81),
    117: dict(varname=33, fmt=49, lblname=33, varlabel=81, vo_v=4),
    118: dict(varname=129, fmt=57, lblname=129, varlabel=321, vo_v=2),
    119: dict(varname=129, fmt=57, lblname=129, varlabel=321, vo_v=3),
}

# legacy (113-115) type codes -> (kind, size); tag formats use numeric codes
LEGACY_NUM = {251: "byte", 252: "int", 253: "long", 254: "float",
              255: "double"}
TAG_NUM = {65530: "byte", 65529: "int", 65528: "long", 65527: "float",
           65526: "double"}
NUM_SIZE = {"byte": 1, "int": 2, "long": 4, "float": 4, "double": 8}

# missing-value thresholds: integers > MAX are missing codes; floats >= CUT
# are (the "." code is exactly the cut, 2^127 / 2^1023); index 0 is "."
MISS_MAX = {"byte": 100, "int": 32740, "long": 2147483620}
MISS_CUT = {"float": 2.0 ** 127, "double": 2.0 ** 1023}
MISS_STEP = {"float": 2.0 ** 115, "double": 2.0 ** 1011}
MISS_NAMES = ["."] + ["." + chr(ord("a") + i) for i in range(26)]

EPOCH_DATE = datetime.date(1960, 1, 1)
EPOCH_DT = datetime.datetime(1960, 1, 1)


def missing_index(kind, x):
    """None if x is a real value, else 0 for '.', 1-26 for .a-.z."""
    if kind in ("byte", "int", "long"):
        mx = MISS_MAX[kind]
        return None if x <= mx else min(int(x - mx - 1), 26)
    if x != x or x in (float("inf"), float("-inf")):
        return 0
    if x < MISS_CUT[kind]:
        return None
    return min(int(round((x - MISS_CUT[kind]) / MISS_STEP[kind])), 26)


def fmt_kind(fmt):
    """Classify a %fmt: td/tc/tm/tq/th/tw/ty for date-ish formats, else None."""
    f = fmt
    if f.startswith("%"):
        f = f[1:]
    if f.startswith("-"):
        f = f[1:]
    if f.startswith("d"):
        return "td"               # old %d... == %td...
    if not f.startswith("t"):
        return None
    body = f[1:]
    if body.startswith(("c", "C")):
        return "tc"               # %tC (leap seconds) treated as %tc
    for k in ("d", "w", "m", "q", "h", "y"):
        if body.startswith(k):
            return "t" + k
    return None                   # %tb business calendars etc.: leave numeric


def convert_datish(kind, x):
    if kind == "td":
        return EPOCH_DATE + datetime.timedelta(days=x)
    if kind == "tc":
        return EPOCH_DT + datetime.timedelta(milliseconds=x)
    if kind == "tm":
        y, m = divmod(1960 * 12 + int(x), 12)
        return datetime.date(y, m + 1, 1)
    if kind == "tq":
        y, q = divmod(1960 * 4 + int(x), 4)
        return datetime.date(y, q * 3 + 1, 1)
    if kind == "th":
        y, h = divmod(1960 * 2 + int(x), 2)
        return datetime.date(y, h * 6 + 1, 1)
    if kind == "tw":
        y, w = divmod(1960 * 52 + int(x), 52)
        return datetime.date(y, 1, 1) + datetime.timedelta(days=7 * w)
    return x                       # ty and unknown: leave numeric


def parse(data, encoding=None, max_rows=None, strict=False):
    # ---- release detection ----
    if data[:11] == b"<stata_dta>":
        i = data.index(b"<release>") + 9
        release = int(data[i:i + 3])
    else:
        release = data[0]
    if release in (120, 121):
        raise ValueError(f"format {release} (alias variables) not supported")
    if release not in LAYOUT:
        raise ValueError(f"not a supported .dta format (release {release})")
    L = LAYOUT[release]
    tagged = release >= 117

    # ---- header ----
    if tagged:
        e = "<" if data[data.index(b"<byteorder>") + 11:
                       data.index(b"<byteorder>") + 14] == b"LSF" else ">"
    else:
        e = "<" if data[1] == 2 else ">"

    def u(off, size):
        return int.from_bytes(data[off:off + size],
                              "little" if e == "<" else "big")

    def cstr(off, width):
        raw = data[off:off + width]
        return raw.split(b"\0")[0]

    if encoding is None:
        encoding = "utf-8" if release >= 118 else "cp1252"
    dec = lambda b: b.decode(encoding, errors="replace")

    if tagged:
        pos = data.index(b"</byteorder>") + 12
        assert data[pos:pos + 3] == b"<K>"
        ksize = 4 if release == 119 else 2
        nvar = u(pos + 3, ksize)
        pos += 3 + ksize + len(b"</K>")
        assert data[pos:pos + 3] == b"<N>"
        nsize = 4 if release == 117 else 8
        nobs = u(pos + 3, nsize)
        pos += 3 + nsize + len(b"</N>")
        assert data[pos:pos + 7] == b"<label>"
        lsize = 1 if release == 117 else 2
        llen = u(pos + 7, lsize)
        label = dec(data[pos + 7 + lsize:pos + 7 + lsize + llen])
        pos += 7 + lsize + llen + len(b"</label>")
        assert data[pos:pos + 11] == b"<timestamp>"
        tlen = data[pos + 11]
        timestamp = data[pos + 12:pos + 12 + tlen].decode("ascii",
                                                          errors="replace")
        # the map: 14 8-byte offsets
        mpos = data.index(b"<map>", pos) + 5
        offs = [u(mpos + 8 * i, 8) for i in range(14)]
        (types_o, names_o, srt_o, fmts_o, lblnames_o, varlabs_o,
         chars_o, data_o, strls_o, vallabs_o) = offs[2:12]
        types_o += len(b"<variable_types>")
        names_o += len(b"<varnames>")
        srt_o += len(b"<sortlist>")
        fmts_o += len(b"<formats>")
        lblnames_o += len(b"<value_label_names>")
        varlabs_o += len(b"<variable_labels>")
        data_o += len(b"<data>")
        strls_o += len(b"<strls>")
        vallabs_o += len(b"<value_labels>")
    else:
        nvar = u(4, 2)
        nobs = u(6, 4)
        label = dec(cstr(10, 81))
        timestamp = cstr(91, 18).decode("ascii", errors="replace")
        types_o = 109

    # ---- variable descriptors ----
    if tagged:
        typ_codes = [u(types_o + 2 * i, 2) for i in range(nvar)]
    else:
        typ_codes = list(data[types_o:types_o + nvar])
        names_o = types_o + nvar
        srt_o = names_o + L["varname"] * nvar
        fmts_o = srt_o + 2 * (nvar + 1)
        lblnames_o = fmts_o + L["fmt"] * nvar
        varlabs_o = lblnames_o + L["lblname"] * nvar

    variables = []
    for i, t in enumerate(typ_codes):
        if tagged:
            if t == 32768:
                kind, width = "strL", 8
            elif 1 <= t <= 2045:
                kind, width = "str", t
            elif t in TAG_NUM:
                kind, width = TAG_NUM[t], NUM_SIZE[TAG_NUM[t]]
            else:
                raise ValueError(f"unknown variable type code {t}")
        else:
            if t in LEGACY_NUM:
                kind, width = LEGACY_NUM[t], NUM_SIZE[LEGACY_NUM[t]]
            elif 1 <= t <= 244:
                kind, width = "str", t
            else:
                raise ValueError(f"unknown variable type code {t}")
        variables.append({
            "name": dec(cstr(names_o + L["varname"] * i, L["varname"])),
            "kind": kind, "width": width,
            "format": dec(cstr(fmts_o + L["fmt"] * i, L["fmt"])),
            "label_set": dec(cstr(lblnames_o + L["lblname"] * i,
                                  L["lblname"])) or None,
            "label": dec(cstr(varlabs_o + L["varlabel"] * i,
                              L["varlabel"])) or None,
        })

    # ---- sort order ----
    ssz = 4 if release == 119 else 2
    sort_by = []
    for i in range(nvar):
        v = u(srt_o + ssz * i, ssz)
        if v == 0:
            break
        sort_by.append(variables[v - 1]["name"])

    # ---- characteristics / expansion fields (skip; find data start) ----
    if tagged:
        pass                                   # map gives data_o directly
    else:
        pos = varlabs_o + L["varlabel"] * nvar
        while True:
            dt = data[pos]
            ln = u(pos + 1, 4)
            pos += 5
            if dt == 0 and ln == 0:
                break
            pos += ln
        data_o = pos

    # ---- data rows ----
    rowsize = sum(v["width"] for v in variables)
    rows_raw = []
    n = nobs if max_rows is None else min(nobs, max_rows)
    pos = data_o
    for _ in range(n):
        row = []
        for v in variables:
            raw = data[pos:pos + v["width"]]
            pos += v["width"]
            row.append(raw)
        rows_raw.append(row)

    # ---- strLs (GSO table), tag formats only ----
    gso = {}
    if tagged and any(v["kind"] == "strL" for v in variables):
        p = strls_o
        osize = 4 if release == 117 else 8
        while data[p:p + 3] == b"GSO":
            gv = u(p + 3, 4)
            go = u(p + 7, osize)
            t = data[p + 7 + osize]
            ln = u(p + 8 + osize, 4)
            content = data[p + 12 + osize:p + 12 + osize + ln]
            if t == 130:
                gso[(gv, go)] = dec(content.rstrip(b"\0"))
            else:                              # t == 129: binary
                gso[(gv, go)] = bytes(content)
            p += 12 + osize + ln

    # ---- value labels ----
    value_labels = {}                          # labname -> {val: text}
    if tagged:
        p = vallabs_o
        while data[p:p + 5] == b"<lbl>":
            p += 5
            ln = u(p, 4)
            labname = dec(cstr(p + 4, L["lblname"]))
            table = data[p + 4 + L["lblname"] + 3:
                         p + 4 + L["lblname"] + 3 + ln]
            value_labels[labname] = _vallab(table, e, dec)
            p += 4 + L["lblname"] + 3 + ln + len(b"</lbl>")
    else:
        p = pos                                # right after the data
        while p + 4 + L["lblname"] + 3 <= len(data):
            ln = u(p, 4)
            labname = dec(cstr(p + 4, L["lblname"]))
            table = data[p + 4 + L["lblname"] + 3:
                         p + 4 + L["lblname"] + 3 + ln]
            value_labels[labname] = _vallab(table, e, dec)
            p += 4 + L["lblname"] + 3 + ln

    # ---- decode cells ----
    vo_v = L.get("vo_v")
    rows = []
    for j, rr in enumerate(rows_raw):
        row = []
        for i, (v, raw) in enumerate(zip(variables, rr)):
            k = v["kind"]
            if k == "str":
                row.append(dec(raw.split(b"\0")[0]))
            elif k == "strL":
                if vo_v == 4:
                    gv, go = struct.unpack(f"{e}II", raw)
                else:
                    if e == "<":
                        gv = int.from_bytes(raw[:vo_v], "little")
                        go = int.from_bytes(raw[vo_v:], "little")
                    else:
                        gv = int.from_bytes(raw[:vo_v], "big")
                        go = int.from_bytes(raw[vo_v:], "big")
                if (gv, go) == (0, 0):
                    row.append("")
                else:
                    if (gv, go) not in gso:
                        raise ValueError(f"strL ({gv},{go}) has no GSO")
                    row.append(gso[(gv, go)])
            else:
                if k == "byte":
                    x = struct.unpack(f"{e}b", raw)[0]
                elif k == "int":
                    x = struct.unpack(f"{e}h", raw)[0]
                elif k == "long":
                    x = struct.unpack(f"{e}i", raw)[0]
                elif k == "float":
                    x = struct.unpack(f"{e}f", raw)[0]
                else:
                    x = struct.unpack(f"{e}d", raw)[0]
                mi = missing_index(k, x)
                row.append(("miss", mi) if mi is not None else x)
        rows.append(row)

    return {
        "release": release, "byteorder": "MSF" if e == ">" else "LSF",
        "nvar": nvar, "nobs": nobs, "label": label, "timestamp": timestamp,
        "encoding": encoding, "variables": variables,
        "value_labels": value_labels, "sort_by": sort_by, "rows": rows,
    }


def _vallab(table, e, dec):
    pre = "<" if e == "<" else ">"
    n, txtlen = struct.unpack(f"{pre}ii", table[:8])
    off = struct.unpack(f"{pre}{n}i", table[8:8 + 4 * n])
    val = struct.unpack(f"{pre}{n}i", table[8 + 4 * n:8 + 8 * n])
    txt = table[8 + 8 * n:8 + 8 * n + txtlen]
    out = {}
    for o, v in zip(off, val):
        out[v] = dec(txt[o:].split(b"\0")[0])
    return out


def label_key(val):
    """Present an int32 value-label key; extended missings as . codes."""
    if val > 2147483620:
        return MISS_NAMES[val - 2147483621]
    return val
