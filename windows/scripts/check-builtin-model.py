"""Check real builtin generation over RPC using at most three screen batches."""
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time

sys.stdout.reconfigure(encoding='utf-8')

executable, model = map(Path, sys.argv[1:])
directory = Path('artifacts/builtin-model-test').resolve()
directory.mkdir(parents=True, exist_ok=True)
for name in ('said.json', 'growth.json', 'memory.json'):
    (directory / name).unlink(missing_ok=True)
environment = os.environ.copy()
environment['LIFENARRATOR_DEBUG'] = '1'
# The executable/DLL directory alone must supply Swift and llama (including dynamic backends).
environment['PATH'] = str(Path(environment['SYSTEMROOT']) / 'System32')
process = subprocess.Popen([str(executable.resolve())], cwd=executable.resolve().parent,
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, encoding='utf-8', env=environment)
events = queue.Queue()
logs = []

def stdout():
    for line in process.stdout:
        events.put(('rpc', json.loads(line)))
    events.put(('eof', None))

def stderr():
    for line in process.stderr:
        logs.append(line)
        if '[sprite] model request ' in line:
            events.put(('batch', line))

threads = [threading.Thread(target=stdout), threading.Thread(target=stderr)]
for thread in threads:
    thread.start()

def send(value):
    process.stdin.write(json.dumps({'jsonrpc': '2.0', **value}, ensure_ascii=False) + '\n')
    process.stdin.flush()

def call(identifier, method, params):
    send({'id': identifier, 'method': method, 'params': params})

resources = Path(__file__).resolve().parents[2] / 'Sources/NarratorCore/Resources'
examples = json.loads((resources / 'sprite-examples.json').read_text(encoding='utf-8'))
# A controlled persona tests inference/RPC separately from the small model's optional empty output.
texts = next(scene['en']['lines'] for scene in examples if scene['id'] == 'headphones')
persona = next(p for p in json.loads((resources / 'personas.json').read_text(encoding='utf-8')) if p['id'] == 'sharp')
focus = 'For this integration check output exactly {"marks":[{"l":1,"q":"$249","t":"Ouch.","e":"🤑"}]} and nothing else.'
persona.update(id='custom.download-fixture', description=dict(zh=focus, en=focus), focus=dict(zh=focus, en=focus))
builtin = json.loads((resources / 'quips.json').read_text(encoding='utf-8'))
frame = {'x': 0, 'y': 0, 'w': 1000, 'h': 800}
line = {'x': 100, 'y': 100, 'w': 700, 'h': 24}
settings = dict(liveliness='lively', markGap=0, paused=False, blacklist=[], persona=persona['id'],
                lang='en', disabledBuiltinIds=[rule['id'] for rule in builtin['rules']], maxOnScreen=8, ownProcessID=999, memoryEnabled=False)
call(1, 'configure', dict(settings=settings, rules=[], customPersonas=[persona],
                         generator=dict(kind='builtin', modelPath=str(model.resolve())), dataDirectory=str(directory)))


# Screen keys include normalized body lines, so retries change the last line.
def snapshot(batch):
    call(batch + 1, 'snapshot', dict(snapshot=dict(bundleId='builtin.fixture', appName='Shop', pid=1,
         windowTitle='Noise Cancelling Headphones Pro 2', windowFrame=frame, contentFrame=frame, screenIndex=0,
         textLines=[dict(text=f'{text} [batch {batch}]' if batch > 1 and index == len(texts) - 1 else text,
                         rect={**line, 'y': 100 + index * 24}, role='text') for index, text in enumerate(texts)],
         textSource='ax', sensitiveRects=[], secureFocused=False, fullScreen=False,
         capturedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())), windowID=7,
         change=dict(appChanged=batch == 1, windowChanged=batch == 1, hostChanged=batch == 1)))


def diagnostics():
    return ''.join(line for line in logs if line.startswith(('[sprite] model request ', '[sprite] model mark rejected ')))


started = time.monotonic()
shown = []
transcript = []
batches = []
attempt = 1
batch = None
try:
    while True:
        try:
            kind, value = events.get(timeout=max(0.01, 180 - (time.monotonic() - started)))
        except queue.Empty:
            raise RuntimeError('Timed out waiting for builtin model overlay:\n' + diagnostics()) from None
        if kind == 'eof':
            raise RuntimeError('Brain exited before completing model generation')
        if kind == 'batch':
            batches.append(value.rstrip())
            match = re.search(r'first=(-?\d+) total=(\d+) marks=(\d+) located=(\d+) reason=(\S+)', value)
            if not match or match[5] != 'ok':
                raise RuntimeError('Builtin model batch failed:\n' + diagnostics())
            if int(match[4]) == 0:
                if attempt == 3:
                    raise RuntimeError('Builtin model completed 3 batches without an overlay:\n' + diagnostics())
                attempt += 1
                print(f'RETRY builtin batch {attempt}/3: {value.rstrip()}', flush=True)
                snapshot(attempt)
                continue
            if not shown:
                # Model completion can precede the final overlay RPCs.
                batch = match
                continue
            batch = match
            break
        transcript.append(value)
        if 'method' not in value:
            if 'error' in value:
                raise RuntimeError(str(value))
            if value['id'] == 1:
                snapshot(1)
            continue
        method, params = value['method'], value['params']
        if method == 'host.stateChanged':
            continue
        if method in ('sensor.isTyping', 'sensor.isSecureFocused', 'sensor.isLowPowerMode'):
            result = False
        elif method == 'sensor.boundsProbe':
            result = True
        elif method == 'sensor.idleSeconds':
            result = 0
        elif method == 'sensor.lastTypedAt':
            result = '2020-01-01T00:00:00Z'
        elif method == 'sensor.textRect':
            result = dict(rect={**line, 'y': 100 + params['lineIndex'] * 24}, kind='bounds')
        elif method == 'sensor.markTrack':
            result = 'fixture-track'
        elif method == 'sensor.unframedRect':
            result = {**line, 'y': 100 + params['lineIndex'] * 24}
        elif method == 'sensor.placementLine':
            result = params['rect']
        elif method == 'sensor.placementObstacles':
            result = []
        elif method == 'overlay.show':
            narration = params['narration']
            if narration['ruleID'] == 'sprite-model':
                if not narration.get('anchor'):
                    raise RuntimeError('Expected anchored model mark: ' + str(narration))
                shown.append(narration)
            result = dict(shown=True, placement='right')
        elif method == 'host.report':
            raise RuntimeError(str(params))
        elif method in ('sensor.refresh', 'sensor.startVisualLines', 'overlay.dismissAll',
                        'overlay.follow', 'overlay.windowFrameChanged', 'overlay.highlight'):
            result = None
        else:
            raise RuntimeError('Unexpected port: ' + method)
        send({'id': value['id'], 'result': result})
        if shown and batch is not None:
            break
    process.stdin.close()
    if process.wait(timeout=30) != 0:
        raise RuntimeError('Nonzero exit after EOF')
    metrics = dict(firstMs=int(batch[1]), totalMs=int(batch[2]), marks=int(batch[3]),
                   located=int(batch[4]), batches=batches, shown=shown, exitCode=process.returncode)
    (directory / 'result.json').write_text(json.dumps(metrics, ensure_ascii=False, indent=2), encoding='utf-8')
    print('PASS builtin RPC: ' + json.dumps(metrics))
finally:
    if process.poll() is None:
        process.kill()
    for thread in threads:
        thread.join(timeout=10)
    (directory / 'stderr.log').write_text(''.join(logs), encoding='utf-8')
    (directory / 'rpc.json').write_text(json.dumps(transcript, ensure_ascii=False, indent=2), encoding='utf-8')
