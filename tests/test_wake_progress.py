"""Exercise the actual local worker pipe; no audio devices, playback or network."""
import base64
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'work/tests/wake-health'
OUT.mkdir(parents=True, exist_ok=True)
events = queue.Queue()
process = subprocess.Popen(
    [sys.executable, '-B', str(ROOT / 'src/wake_worker.py'), '--model-dir',
     str(ROOT / 'runtime/models/wake'), '--phrase', '\u4f60\u597d\u58f0\u4f34'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    text=True, encoding='utf-8', env={**os.environ, 'PYTHONIOENCODING': 'utf-8'},
    creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
)
threading.Thread(target=lambda: [events.put(line.strip()) for line in process.stdout], daemon=True).start()
checks = []

def check(condition, name):
    if not condition:
        raise AssertionError(name)
    checks.append(name)

try:
    check(events.get(timeout=12) == 'READY', 'Real model initialized')
    try:
        unsolicited = events.get(timeout=0.7)
    except queue.Empty:
        unsolicited = None
    check(unsolicited is None, 'No timer heartbeat before any PCM')
    block = base64.b64encode(bytes(1280)).decode('ascii')
    process.stdin.write(block + '\n')
    process.stdin.flush()
    check(events.get(timeout=3) == 'PROGRESS\t640', 'First actual silent block is acknowledged')
    for _ in range(24):
        process.stdin.write(block + '\n')
    process.stdin.flush()
    check(events.get(timeout=3) == 'PROGRESS\t8960', 'Audio-time progress at 0.5 second cadence')
    process.stdin.write('END\n')
    process.stdin.flush()
    process.stdin.close()
    check(process.wait(timeout=5) == 0, 'END completes cleanly')
    time.sleep(0.05)
    remaining = []
    while not events.empty():
        remaining.append(events.get_nowait())
    check(not remaining, 'END synthetic padding does not inflate input progress')
    check(not process.stderr.read().strip(), 'No worker stderr error')
    report = {'passed': len(checks), 'checks': checks, 'devices_opened': False,
              'model': 'production local KWS', 'audio': 'generated zero PCM only'}
    (OUT / 'worker-progress-result.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report))
finally:
    if process.poll() is None:
        process.kill()
    process.wait(timeout=5)
