# SPDX-License-Identifier: Apache-2.0
#
# Synthesizes encrypted.mdb from jet4.mdb: sets a non-zero database key in the
# (RC4-masked) header and scrambles every page after page 0, which is what an
# RC4-"encoded" Jet database looks like to a reader without the key. Truncated
# to 8 pages -- the reader must refuse the file at the header, so the rest of
# the file is irrelevant. Run after MakeFixtures.java:
#
#   python3 make_encrypted.py

from pathlib import Path

HERE = Path(__file__).parent
PAGE = 4096


def rc4(key, n):
    S = list(range(256))
    j = 0
    for i in range(256):
        j = (j + S[i] + key[i % len(key)]) % 256
        S[i], S[j] = S[j], S[i]
    out, i, j = [], 0, 0
    for _ in range(n):
        i = (i + 1) % 256
        j = (j + S[i]) % 256
        S[i], S[j] = S[j], S[i]
        out.append(S[(S[i] + S[j]) % 256])
    return bytes(out)


src = bytearray((HERE / "jet4.mdb").read_bytes()[: 8 * PAGE])

# db_key lives at file offset 0x3E inside the region masked with the RC4
# keystream of the fixed key C7 DA 39 6B (region starts at 0x18). To make the
# unmasked value read as 0x12345678, store keystream XOR value.
stream = rc4(bytes([0xC7, 0xDA, 0x39, 0x6B]), 128)
want = (0x12345678).to_bytes(4, "little")
for i in range(4):
    src[0x3E + i] = stream[0x3E - 0x18 + i] ^ want[i]

# scramble all pages after page 0, as page-level RC4 encoding would
for off in range(PAGE, len(src)):
    src[off] ^= 0xA5

(HERE / "encrypted.mdb").write_bytes(bytes(src))
print(f"wrote encrypted.mdb ({len(src)} bytes)")
