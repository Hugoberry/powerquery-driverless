import pandas as pd, pyogrio
def _v():
    # pyogrio maps fid to the index, so it is added back to match the
    # driverless reader, which keeps fid as an ordinary column.
    gdf = pyogrio.read_dataframe('__PERF_OUT__', fid_as_index=True)
    return int(gdf.notna().sum().sum()) + len(gdf)
result = pd.DataFrame({'v': [_v()]})
