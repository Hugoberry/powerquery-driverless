# Fixtures

All fixtures are synthetic. `jet4.mdb` and `ace.accdb` are written by
[`MakeFixtures.java`](MakeFixtures.java) (Jackcess 4.0.7, Apache-2.0);
`encrypted.mdb` is synthesized from `jet4.mdb` by
[`make_encrypted.py`](make_encrypted.py). Reruns are not byte-identical (the
format embeds creation timestamps), but the logical content below is fixed.

Access files cannot be tiny: a freshly created database is a few hundred KB of
system tables and allocation maps before the first user row. These are as small
as the format allows.

Every value below was verified cell-by-cell against Jackcess reading the same
files (via a canonical TSV dump and a byte-level reference reader) before the M
implementation was written; the M reader implements exactly the validated logic.

## jet4.mdb (Jet 4 / Access 2000 format, version byte 0x01)

Navigation table must list exactly: `Empty`, `Many`, `Types`, `Unicode`, `Wide`.
With `[IncludeSystemObjects = true]` the `MSys*` tables appear as well.

### Types, 4 rows

One column per data type. Proves fixed and variable columns, the null bitmap,
booleans stored in the null bitmap, LVAL memo storage (inline, single-page, and
multi-page), GUID formatting, Decimal sign and scale, and OLE date handling
including a pre-1900 date (negative OLE date, fraction read as magnitude).

| Id | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| TByte | 7 | null | 255 | 0 |
| TInt | -12345 | null | 32767 | 0 |
| TLong | 123456789 | null | -2147483648 | 0 |
| TCurrency | 1234.5678 | null | -0.0001 | 0 |
| TFloat | 1.5 | null | -3.25 | 0 |
| TDouble | 2.75 | null | -10000000000 | 0 |
| TDate | 2026-07-15 13:45:30 | null | 1899-12-25 06:00:00 | 1899-12-30 00:00:00 |
| TText | hello | null | Ünïcødé テスト | (empty string) |
| TMemo | short memo | null | "0123456789" repeated 2000 times (20,000 chars) | (empty string) |
| TBool | true | false | true | false |
| TGuid | {00112233-4455-6677-8899-AABBCCDDEEFF} | null | {FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF} | null |
| TNumeric | 1234.5678 | null | -9999.9999 | 0.0001 |
| TBinary | 01 02 03 04 | null | 200 bytes: 00 01 .. C7 | 0-byte binary |
| TOle | 10,000 bytes: (i * 7) mod 256 | null | null | null |

Notes:

- TByte row 3 is 255: Access Byte is unsigned 0..255. Jackcess reports Java's
  signed byte (-1); 255 is correct.
- The 20,000-char memo exceeds one 4 KB page, proving the multi-page LVAL chain.
  `short memo` proves the small-value path; the empty memo proves length 0.
- Row 2 proves every type's null path in one null bitmap.

### Empty, 0 rows

Columns `Id`, `Note`. Proves a table with no data pages materializes as an empty
typed table.

### Many, 2999 rows

Columns `Id` (Long), `Val` (Text). 3000 rows `row-0001`..`row-3000` were
inserted, then:

- `Id = 77` was deleted: its slot carries the deleted flag and must be skipped.
  The row is absent and the total is 2999.
- `Id = 42` was grown to `"grown "` repeated 40 times and trimmed (239 chars).
  The row no longer fits its page, so its home slot became a 4-byte pointer to
  an overflow page (flag 0x4000) and the target slot is flagged 0x8000. Exactly
  one row with `Id = 42` must be present, with the 239-char value: this proves
  pointer-following without double counting.

Also proves multi-page data (about 24 data pages) driven by the usage map.

### Unicode, 5 rows

| Id | Txt |
|---|---|
| 1 | plain ascii |
| 2 | 日本語テキスト |
| 3 | mix: ascii + Ωμέγα + 中文 |
| 4 | (empty string) |
| 5 | null |

Proves the Jet 4 Unicode compression scheme: row 1 is fully compressed (one byte
per char), row 2 is fully uncompressed UTF-16LE, row 3 toggles between modes
mid-string, row 4 distinguishes empty from null.

### Wide, 2 rows

150 Text columns `C001`..`C150`. The column definitions and names do not fit one
4 KB page, proving multi-page table definitions. Row 1 holds `v001`..`v150`
(also proves a 150-entry variable-offset table); row 2 is all nulls.

## ace.accdb (ACE / Access 2016 format, version byte 0x05)

Same tables and expectations as `jet4.mdb`, with two differences:

- `Types` has one extra column `TBigInt` (Big Integer, ACE 2016+ only):
  42, null, 4503599627370496, -1. The third value is 2^52 and exact; larger
  magnitudes would lose precision in M doubles.
- `Many` holds 1000 inserted rows, minus the same deleted `Id = 77` (999 rows),
  with the same grown `Id = 42`.

Proves the ACE branch: `Standard ACE DB` signature, version byte 0x05, and the
unchanged Jet 4 page layout.

## encrypted.mdb

A copy of the first 8 pages of `jet4.mdb` with a non-zero database key written
into the RC4-masked header region and every page after page 0 scrambled, which
is what a key-encoded Jet database looks like without the key. The reader must
refuse it with a `DataFormat.Error` that names encryption as the reason, before
touching any table. (Real Access 2007+ password encryption also scrambles page
2, which the reader detects the same way.)
