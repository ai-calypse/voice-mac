"""Record real offline engine validation as an asciinema v2 terminal session."""
import json
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[1]
out = root / 'docs/demos/engine-session.cast'
out.parent.mkdir(parents=True, exist_ok=True)
started = time.monotonic()
events = []

def emit(text):
    print(text, end='', flush=True)
    events.append([round(time.monotonic() - started, 6), 'o', text.replace('\n', '\r\n')])

for command in [['npm', 'run', 'typecheck'], ['npm', 'test']]:
    emit('$ ' + ' '.join(command) + '\n')
    result = subprocess.run(command, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    emit(result.stdout)
    if result.returncode:
        raise SystemExit(result.returncode)

emit('$ node engine/rpc.ts\n')
engine = subprocess.Popen(['node', 'engine/rpc.ts'], cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, bufsize=1)
try:
    ready = engine.stdout.readline()
    assert json.loads(ready)['event'] == 'ready'
    emit(ready)
    for request in ['{"id":1,"method":"ping"}', 'malformed input', '{"id":2,"method":"ping"}']:
        emit('> ' + request + '\n')
        engine.stdin.write(request + '\n')
        engine.stdin.flush()
        response = engine.stdout.readline()
        assert response
        emit(response)
    engine.stdin.close()
    assert engine.wait(timeout=10) == 0
finally:
    if engine.poll() is None:
        engine.kill()
        engine.wait()

header = {'version': 2, 'width': 108, 'height': 30, 'timestamp': int(time.time()),
          'title': 'Voice Mac: real offline checks and engine transport; no live AI task',
          'env': {'TERM': 'xterm-256color'}}
out.write_text('\n'.join(json.dumps(item) for item in [header] + events) + '\n')
print('Wrote docs/demos/engine-session.cast')
