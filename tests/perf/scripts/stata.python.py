import pandas as pd
def _v():
    return int(pd.read_stata('__PERF_OUT__').notna().sum().sum())
result = pd.DataFrame({'v': [_v()]})
