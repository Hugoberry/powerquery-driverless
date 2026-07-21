import pandas as pd, scipy.io as sio
def _v():
    m = sio.loadmat('__PERF_OUT__')
    return int(sum(v.size for k, v in m.items() if not k.startswith('__')))
result = pd.DataFrame({'v': [_v()]})
