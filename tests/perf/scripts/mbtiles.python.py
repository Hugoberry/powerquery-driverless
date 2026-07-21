import pandas as pd, sqlite3, gzip
def _v():
    con = sqlite3.connect('__PERF_OUT__')
    total = 0
    for (blob,) in con.execute('SELECT tile_data FROM tiles'):
        total += 1
        if blob[:2] == b'\x1f\x8b':
            blob = gzip.decompress(blob)
        total += len(blob)
    con.close()
    return total
result = pd.DataFrame({'v': [_v()]})
