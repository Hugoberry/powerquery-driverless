import fastavro, pandas as pd
def _v():
    with open('__PERF_OUT__', 'rb') as f:
        return int(pd.DataFrame(list(fastavro.reader(f))).notna().sum().sum())
result = pd.DataFrame({'v': [_v()]})
