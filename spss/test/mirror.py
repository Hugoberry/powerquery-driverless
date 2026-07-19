# SPDX-License-Identifier: Apache-2.0
#
# Pure-Python mirror of the parse logic destined for Spss.Document.pq.
# Byte-level only — no readstat, no pyreadstat. Every algorithmic decision in
# the M reader is prototyped here first, then this mirror is cross-validated
# cell-by-cell against pyreadstat (ReadStat) by check_mirror.py.
#
# Structure intentionally parallels the M reader:
#   parse(data) -> {header, variables, value_labels, documents, rows, encoding}

import struct
import zlib

SYSMIS_DEFAULT = struct.unpack("<d", struct.pack("<Q", 0xFFEFFFFFFFFFFFFF))[0]

FORMAT_NAMES = {
    1: "A", 2: "AHEX", 3: "COMMA", 4: "DOLLAR", 5: "F", 6: "IB", 7: "PIBHEX",
    8: "P", 9: "PIB", 10: "PK", 11: "RB", 12: "RBHEX", 15: "Z", 16: "N",
    17: "E", 20: "DATE", 21: "TIME", 22: "DATETIME", 23: "ADATE", 24: "JDATE",
    25: "DTIME", 26: "WKDAY", 27: "MONTH", 28: "MOYR", 29: "QYR", 30: "WKYR",
    31: "PCT", 32: "DOT", 33: "CCA", 34: "CCB", 35: "CCC", 36: "CCD",
    37: "CCE", 38: "EDATE", 39: "SDATE", 40: "MTIME", 41: "YMDHMS",
}
DATE_FORMATS = {20, 23, 24, 28, 29, 30, 38, 39}       # -> date
DATETIME_FORMATS = {22, 41}                            # -> datetime
TIME_FORMATS = {21, 25, 40}                            # -> duration

MEASURES = {1: "Nominal", 2: "Ordinal", 3: "Scale"}
ALIGNMENTS = {0: "Left", 1: "Right", 2: "Center"}

ENCODING_MAP = {   # subtype-20 string or subtype-3 charcode -> python codec
    "UTF-8": "utf-8", "UTF8": "utf-8",
    2: "ascii", 3: "cp1252", 1252: "cp1252", 65001: "utf-8",
    28591: "iso-8859-1",
}


def fmt_text(packed, true_width=None):
    # the packed width field is one byte, so very long strings need the
    # variable's true width passed in
    ftype = (packed >> 16) & 0xFF
    width = (packed >> 8) & 0xFF
    dec = packed & 0xFF
    name = FORMAT_NAMES.get(ftype, f"?{ftype}")
    if true_width is not None and true_width > width:
        width = true_width
    return f"{name}{width}" + (f".{dec}" if dec else "")


def parse(data):
    def u32(off):
        return struct.unpack_from("<I", data, off)[0]

    def i32(off):
        return struct.unpack_from("<i", data, off)[0]

    def f64(off):
        return struct.unpack_from("<d", data, off)[0]

    # ---- header (176 bytes) ----
    magic = data[0:4]
    if magic not in (b"$FL2", b"$FL3"):
        raise ValueError("not an SPSS system file (bad magic)")
    layout = i32(64)
    if layout not in (2, 3):
        raise ValueError("big-endian or unrecognized layout, not supported")
    compression = i32(72)
    weight_index = i32(76)
    ncases = i32(80)
    bias = f64(84)
    header = {
        "product": data[4:64].decode("latin-1").strip(),
        "compression": compression,
        "weight_index": weight_index,
        "ncases": ncases,
        "bias": bias,
        "creation": (data[92:101] + b" " + data[101:109]).decode("latin-1").strip(),
        "label_raw": data[109:173],
    }

    # ---- dictionary records ----
    pos = 176
    slots = []            # one entry per 8-byte case element
    value_label_sets = [] # (labels dict raw-bytes -> raw-bytes, slot indices)
    documents = []
    ext = {}              # subtype -> payload bytes
    sysmis = SYSMIS_DEFAULT

    while True:
        rectype = i32(pos)
        pos += 4
        if rectype == 2:
            vtype, has_label, n_missing, pf, wf = struct.unpack_from("<5i", data, pos)
            pos += 20
            name = data[pos:pos + 8]
            pos += 8
            label = None
            if has_label:
                llen = i32(pos)
                pos += 4
                label = data[pos:pos + llen]
                pos += llen + ((4 - llen % 4) % 4)
            missing = []
            if n_missing:
                for _ in range(abs(n_missing)):
                    missing.append(data[pos:pos + 8])
                    pos += 8
            slots.append({
                "type": vtype, "name": name, "label": label,
                "n_missing": n_missing, "missing": missing,
                "print_fmt": pf, "write_fmt": wf,
            })
        elif rectype == 3:
            n = i32(pos)
            pos += 4
            labels = []
            for _ in range(n):
                val = data[pos:pos + 8]
                pos += 8
                llen = data[pos]
                pos += 1
                lab = data[pos:pos + llen]
                pos += llen
                pos += (8 - (llen + 1) % 8) % 8
                labels.append((val, lab))
            # rec 4 must follow immediately
            if i32(pos) != 4:
                raise ValueError("value label record not followed by variable record")
            nvars = i32(pos + 4)
            pos += 8
            idxs = [i32(pos + 4 * i) for i in range(nvars)]
            pos += 4 * nvars
            value_label_sets.append((labels, idxs))
        elif rectype == 6:
            n = i32(pos)
            pos += 4
            for _ in range(n):
                documents.append(data[pos:pos + 80])
                pos += 80
        elif rectype == 7:
            subtype = i32(pos)
            size = i32(pos + 4)
            count = i32(pos + 8)
            pos += 12
            payload = data[pos:pos + size * count]
            pos += size * count
            ext[subtype] = payload
        elif rectype == 999:
            pos += 4      # filler int32
            break
        else:
            raise ValueError(f"unknown record type {rectype} at {pos - 4}")

    data_start = pos

    # ---- machine/float info ----
    if 4 in ext and len(ext[4]) >= 8:
        sysmis = struct.unpack_from("<d", ext[4], 0)[0]

    # ---- encoding ----
    encoding = None
    if 20 in ext:
        encoding = ENCODING_MAP.get(ext[20].decode("ascii").strip().upper())
        if encoding is None:
            encoding = ext[20].decode("ascii").strip()   # try codec name as-is
    elif 3 in ext and len(ext[3]) >= 32:
        charcode = struct.unpack_from("<i", ext[3], 28)[0]
        encoding = ENCODING_MAP.get(charcode, f"cp{charcode}")
    if encoding is None:
        encoding = "cp1252"

    dec = lambda b: b.decode(encoding, errors="replace")

    # ---- variables from slots (merge continuations) ----
    variables = []       # dict: name, width, slot (first), elements
    slot_to_var = {}     # first-slot index (0-based) -> var position
    i = 0
    while i < len(slots):
        s = slots[i]
        if s["type"] == -1:
            raise ValueError(f"orphan continuation record at slot {i}")
        width = s["type"]
        nelem = 1 if width == 0 else (width + 7) // 8
        for j in range(1, nelem):
            if slots[i + j]["type"] != -1:
                raise ValueError(f"expected continuation at slot {i + j}")
        slot_to_var[i] = len(variables)
        variables.append({
            "short": dec(s["name"]).strip(),
            "name": dec(s["name"]).strip(),
            "width": width,
            "label": dec(s["label"]).strip() if s["label"] else None,
            "n_missing": s["n_missing"],
            "missing_raw": s["missing"],
            "print_fmt": s["print_fmt"],
            "write_fmt": s["write_fmt"],
            "slot": i,
            "elements": nelem,
            "segments": [(width, nelem)],   # (declared width, elements)
        })
        i += nelem

    # ---- subtype 13: long variable names ----
    if 13 in ext:
        mapping = {}
        for pair in ext[13].split(b"\t"):
            if b"=" in pair:
                short, longn = pair.split(b"=", 1)
                mapping[dec(short).strip()] = dec(longn).strip()
        for v in variables:
            v["name"] = mapping.get(v["short"], v["name"])

    # ---- subtype 14: very long strings (merge 255-wide segments) ----
    if 14 in ext:
        vls = {}
        for pair in ext[14].replace(b"\x00", b"").split(b"\t"):
            if b"=" in pair:
                short, ln = pair.split(b"=", 1)
                vls[dec(short).strip()] = int(ln)
        variables_out = []
        i = 0
        while i < len(variables):
            v = variables[i]
            true_w = vls.get(v["short"])
            if true_w and true_w > 255:
                nseg = (true_w + 251) // 252
                segs, elements = [], 0
                for k in range(nseg):
                    sv = variables[i + k]
                    segs.append((sv["width"], sv["elements"]))
                    elements += sv["elements"]
                variables_out.append(dict(v, width=true_w, elements=elements,
                                          segments=segs))
                i += nseg
            else:
                variables_out.append(v)
                i += 1
        variables = variables_out
        slot_to_var = {v["slot"]: k for k, v in enumerate(variables)}

    # ---- subtype 11: measure / display width / alignment ----
    if 11 in ext:
        vals = struct.unpack_from(f"<{len(ext[11]) // 4}i", ext[11])
        # one triple per pre-merge variable record; segments of a merged VLS
        # each had a triple — apply the first, skip the rest
        triples = [vals[k:k + 3] for k in range(0, len(vals), 3)]
        ti = 0
        for v in variables:
            if ti < len(triples):
                m, w, a = triples[ti]
                v["measure"] = MEASURES.get(m)
                v["display_width"] = w
                v["alignment"] = ALIGNMENTS.get(a)
            ti += len(v["segments"])

    # ---- decode the missing-value spec per variable ----
    for v in variables:
        raw, n = v["missing_raw"], v["n_missing"]
        if n == 0:
            v["missing"] = None
        elif v["width"] == 0:
            nums = [struct.unpack("<d", r)[0] for r in raw]
            if n < 0:
                lo, hi, rest = nums[0], nums[1], nums[2:]
                v["missing"] = {"lo": lo, "hi": hi, "values": rest}
            else:
                v["missing"] = {"values": nums}
        else:
            v["missing"] = {"values": [dec(r).rstrip() for r in raw]}

    # ---- value labels ----
    value_labels = []    # (var name, value, label)
    for labels, idxs in value_label_sets:
        for idx in idxs:
            var = variables[slot_to_var[idx - 1]]
            for raw, lab in labels:
                if var["width"] == 0:
                    val = struct.unpack("<d", raw)[0]
                else:
                    val = dec(raw).rstrip()
                value_labels.append((var["name"], val, dec(lab)))

    # ---- subtype 21: long string value labels ----
    if 21 in ext:
        p, payload = 0, ext[21]
        while p < len(payload):
            nlen = struct.unpack_from("<i", payload, p)[0]; p += 4
            vname = dec(payload[p:p + nlen]); p += nlen
            p += 4                                    # variable width, unused
            nlab = struct.unpack_from("<i", payload, p)[0]; p += 4
            for _ in range(nlab):
                vlen = struct.unpack_from("<i", payload, p)[0]; p += 4
                val = dec(payload[p:p + vlen]).rstrip(); p += vlen
                llen = struct.unpack_from("<i", payload, p)[0]; p += 4
                lab = dec(payload[p:p + llen]); p += llen
                # subtype 21 names are long names already
                value_labels.append((vname, val, lab))

    n_elements = sum(v["elements"] for v in variables)

    # ---- raw case elements ----
    # Each element token: float (numeric value), bytes (8 raw bytes), or None
    # (system-missing). Compression 1/2 share the bytecode decoder.
    def elements_uncompressed(buf):
        toks = []
        for off in range(0, len(buf) - 7, 8):
            toks.append(buf[off:off + 8])
        return toks

    def elements_bytecode(buf):
        toks = []
        pos = 0
        done = False
        while pos + 8 <= len(buf) and not done:
            cmds = buf[pos:pos + 8]
            pos += 8
            for c in cmds:
                if c == 0:
                    continue
                elif c == 252:
                    done = True
                    break
                elif c == 253:
                    toks.append(buf[pos:pos + 8])
                    pos += 8
                elif c == 254:
                    toks.append(b" " * 8)
                elif c == 255:
                    toks.append(None)
                else:
                    toks.append(float(c) - bias)
        return toks

    if compression == 0:
        tokens = elements_uncompressed(data[data_start:])
    elif compression == 1:
        tokens = elements_bytecode(data[data_start:])
    elif compression == 2:
        zh_ofs, zt_ofs, zt_len = struct.unpack_from("<qqq", data, data_start)
        n_blocks = struct.unpack_from("<i", data, zt_ofs + 20)[0]
        stream = b""
        for k in range(n_blocks):
            d = zt_ofs + 24 + 24 * k
            _, c_ofs, u_size, c_size = struct.unpack_from("<qqii", data, d)
            block = zlib.decompress(data[c_ofs:c_ofs + c_size])
            if len(block) != u_size:
                raise ValueError("zsav block size mismatch")
            stream += block
        tokens = elements_bytecode(stream)
    else:
        raise ValueError(f"unknown compression {compression}")

    n_cases = len(tokens) // n_elements if n_elements else 0
    if ncases >= 0:
        n_cases = min(n_cases, ncases)

    # ---- assemble cases ----
    def num_of(tok):
        if tok is None:
            return None
        if isinstance(tok, float):
            v = tok
        else:
            v = struct.unpack("<d", tok)[0]
        return None if v == sysmis else v

    def bytes_of(tok):
        if tok is None:
            return b" " * 8
        if isinstance(tok, float):
            raise ValueError("numeric token in string column")
        return tok

    rows = []
    for c in range(n_cases):
        base = c * n_elements
        row = []
        e = 0
        for v in variables:
            if v["width"] == 0:
                row.append(num_of(tokens[base + e]))
                e += 1
            else:
                # per PSPP spec: data is packed tightly, 255 bytes per
                # segment; unused space at the end of the allocated
                # segments is ignored. Contribute min(255, stored bytes)
                # per segment, then truncate to the true width.
                chunks = []
                for seg_w, seg_elems in v["segments"]:
                    seg = b"".join(bytes_of(tokens[base + e + k])
                                   for k in range(seg_elems))
                    e += seg_elems
                    chunks.append(seg[:255])
                row.append(dec(b"".join(chunks)[:v["width"]]).rstrip())
        rows.append(row)

    return {
        "header": header,
        "encoding": encoding,
        "file_label": dec(header["label_raw"]).strip(),
        "variables": variables,
        "value_labels": value_labels,
        "documents": [dec(d).rstrip() for d in documents],
        "rows": rows,
        "n_elements": n_elements,
        "sysmis": sysmis,
    }
