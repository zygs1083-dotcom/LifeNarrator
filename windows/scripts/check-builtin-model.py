"""Run one real builtin batch over RPC using only the packaged runtime."""
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
import time

executable, model = map(Path, sys.argv[1:])
directory = Path('artifacts/builtin-model-test').resolve()
directory.mkdir(parents=True, exist_ok=True)
for name in ('said.json', 'growth.json', 'memories.json'):
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

frame = {'x': 0, 'y': 0, 'w': 1000, 'h': 800}
line = {'x': 100, 'y': 100, 'w': 700, 'h': 24}
settings = dict(liveliness='lively', markGap=0, paused=False, blacklist=[], persona='gentle',
                lang='zh', disabledBuiltinIds=[], maxOnScreen=1, ownProcessID=999, memoryEnabled=False)
call(1, 'configure', dict(settings=settings, rules=[], customPersonas=[],
                         generator=dict(kind='builtin', modelPath=str(model.resolve())), dataDirectory=str(directory)))
started = time.monotonic()
shown = []
transcript = []
try:
    while True:
        kind, value = events.get(timeout=max(0.01, 180 - (time.monotonic() - started)))
        if kind == 'eof':
            raise RuntimeError('Brain exited before completing model generation')
        if kind == 'batch':
            match = re.search(r'first=(\d+) total=(\d+) marks=(\d+) located=(\d+) reason=(\S+)', value)
            if not match or match[5] != 'ok' or int(match[4]) < 1:
                raise RuntimeError('No located model marks: ' + value)
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
                call(2, 'snapshot', dict(snapshot=dict(bundleId='builtin.fixture', appName='Fixture', pid=1,
                     windowTitle='工作备忘', windowFrame=frame, contentFrame=frame, screenIndex=0,
                     textLines=[dict(text=text, rect={**line, 'y': 100 + index * 80}, role='text')
                                for index, text in enumerate(['这杯咖啡售价999元。', '现在下单，预计2099年发货。',
                                                              '今日会议预计持续八小时。', '本周计划每天加班到凌晨三点。'])],
                     textSource='ax', sensitiveRects=[], secureFocused=False, fullScreen=False,
                     capturedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())), windowID=7,
                     change=dict(appChanged=True, windowChanged=True, hostChanged=True)))
            continue
        method, params = value['method'], value['params']
        if method in ('sensor.isTyping', 'sensor.isSecureFocused', 'sensor.isLowPowerMode'):
            result = False
        elif method == 'sensor.boundsProbe':
            result = True
        elif method == 'sensor.idleSeconds':
            result = 0
        elif method == 'sensor.lastTypedAt':
            result = '2020-01-01T00:00:00Z'
        elif method == 'sensor.textRect':
            result = dict(rect=line, kind='bounds')
        elif method == 'sensor.markTrack':
            result = 'fixture-track'
        elif method in ('sensor.unframedRect', 'sensor.placementLine'):
            result = line
        elif method == 'sensor.placementObstacles':
            result = []
        elif method == 'overlay.show':
            narration = params['narration']
            if narration['ruleID'] != 'sprite-model' or not narration.get('anchor'):
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
        if shown and 'batch' in locals():
            break
    process.stdin.close()
    if process.wait(timeout=30) != 0:
        raise RuntimeError('Nonzero exit after EOF')
    metrics = dict(firstMs=int(batch[1]), totalMs=int(batch[2]), marks=int(batch[3]),
                   located=int(batch[4]), shown=shown, exitCode=process.returncode)
    (directory / 'result.json').write_text(json.dumps(metrics, ensure_ascii=False, indent=2), encoding='utf-8')
    print('PASS builtin RPC: ' + json.dumps(metrics, ensure_ascii=False))
finally:
    if process.poll() is None:
        process.kill()
    for thread in threads:
        thread.join(timeout=10)
    (directory / 'stderr.log').write_text(''.join(logs), encoding='utf-8')
    (directory / 'rpc.json').write_text(json.dumps(transcript, ensure_ascii=False, indent=2), encoding='utf-8')
