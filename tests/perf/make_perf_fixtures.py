#!/usr/bin/env python3
"""Generate large fixtures for the CI perf benchmark. Stdlib only.

The row counts are deliberately parameters: the dbf reader on current main is
quadratic in file position, so the baseline run needs a modest default; bump it
from the workflow_dispatch inputs once the Binary.Range branch has landed.
"""
import argparse
import datetime
import os
import random
import sqlite3
import struct


def make_sqlite(path: str, rows: int) -> None:
    if os.path.exists(path):
        os.remove(path)
    con = sqlite3.connect(path)
    con.execute(
        "CREATE TABLE data (id INTEGER PRIMARY KEY, name TEXT, value REAL, flag INTEGER)"
    )
    rng = random.Random(42)
    con.executemany(
        "INSERT INTO data VALUES (?,?,?,?)",
        ((i, f"row-{i:07d}", rng.random() * 1000, i % 2) for i in range(rows)),
    )
    con.commit()
    con.close()


def make_dbf(path: str, rows: int) -> None:
    # dBASE III: ID N(10,0), NAME C(20), VALUE N(12,2)
    fields = [(b"ID", b"N", 10, 0), (b"NAME", b"C", 20, 0), (b"VALUE", b"N", 12, 2)]
    reclen = 1 + sum(f[2] for f in fields)
    header_len = 32 + 32 * len(fields) + 1
    rng = random.Random(42)
    today = datetime.date(2026, 1, 1)
    with open(path, "wb") as f:
        f.write(
            struct.pack(
                "<B3BLHH20x",
                0x03,
                today.year - 1900,
                today.month,
                today.day,
                rows,
                header_len,
                reclen,
            )
        )
        for name, ftype, flen, fdec in fields:
            f.write(struct.pack("<11sc4xBB14x", name, ftype, flen, fdec))
        f.write(b"\x0D")
        for i in range(rows):
            rec = (
                b" "
                + str(i).rjust(10).encode()
                + f"row-{i:07d}".ljust(20).encode()
                + f"{rng.random() * 1000:.2f}".rjust(12).encode()
            )
            f.write(rec)
        f.write(b"\x1A")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "out"))
    ap.add_argument("--sqlite-rows", type=int, default=1_000_000)
    ap.add_argument("--dbf-rows", type=int, default=20_000)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    make_sqlite(os.path.join(args.out, "bulk.db"), args.sqlite_rows)
    make_dbf(os.path.join(args.out, "bulk.dbf"), args.dbf_rows)
    for name in ("bulk.db", "bulk.dbf"):
        p = os.path.join(args.out, name)
        print(f"{name}: {os.path.getsize(p):,} bytes")


if __name__ == "__main__":
    main()
