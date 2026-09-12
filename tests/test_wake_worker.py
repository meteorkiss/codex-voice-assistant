"""Evaluate exact local wake keywords on self-authored positive and negative audio."""
import json
from pathlib import Path
import sys
import time
import wave

sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'src'))
import numpy as np
from wake_worker import Spotter

fixtures=ROOT/'tests'/'fixtures'/'wake'
manifest=json.loads((fixtures/'manifest.json').read_text(encoding='utf-8'))
cases=[]
for threshold in (0.35,0.5,0.65):
    for case in manifest['cases']:
        started=time.perf_counter()
        spotter=Spotter(ROOT/'runtime'/'models'/'wake',manifest['phrase'],threshold)
        with wave.open(str(fixtures/(case['name']+'.wav')),'rb') as w:
            samples=np.frombuffer(w.readframes(w.getnframes()),dtype='<i2').astype(np.float32)/32768.0
        samples=np.concatenate((samples,np.zeros(16000,dtype=np.float32)))
        found=''
        for offset in range(0,len(samples),640):
            found=spotter.accept(samples[offset:offset+640])
            if found: break
        cases.append({'threshold':threshold,'name':case['name'],'expected':case['expected'],'actual':bool(found),'passed':bool(found)==case['expected'],'elapsed':round(time.perf_counter()-started,3)})
report={'phrase':manifest['phrase'],'cases':cases}
output=ROOT/'work'/'tests'/'wake'/'kws-corpus-result.json'
output.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(report,ensure_ascii=True,indent=2))
sys.exit(0 if all(c['passed'] for c in cases if c['threshold'] in (0.35,0.5)) else 1)
