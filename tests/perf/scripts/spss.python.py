import pandas as pd, pyreadstat
def _v():
    df, meta = pyreadstat.read_sav('__PERF_OUT__')
    return int(df.notna().sum().sum())
result = pd.DataFrame({'v': [_v()]})
