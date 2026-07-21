import pandas as pd
from evtx import PyEvtxParser
def _v():
    p = PyEvtxParser('__PERF_OUT__')
    return sum(1 for _ in p.records())
result = pd.DataFrame({'v': [_v()]})
