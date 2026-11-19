#!/usr/bin/env python3
"""Integration: real supervisor/PTY/IPC with a fake Claude, no login or network."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix="iremote-service-test-'"))
folder_a = root / 'folder a'
folder_b = root / 'folder b'
folder_a.mkdir()
folder_b.mkdir()
service = root / 'state'
service.mkdir(mode=0o700)
fake = root / "claude's mock"
fake.write_text('''#!/usr/bin/python3
import json,os,select,signal,sys,time,tty
from pathlib import Path
root=Path(os.environ['IREMOTEAIPEEK_SERVICE_DIR'])
def event(name):
 with (root/'events').open('a') as f:f.write(json.dumps({'event':name,'pid':os.getpid(),'cwd':os.getcwd(),'args':sys.argv[1:]})+'\\n')
def stop(*args):
 event('stop');sys.exit(0)
signal.signal(signal.SIGINT,stop)
signal.signal(signal.SIGTERM,stop)
tty.setraw(sys.stdin.fileno())
event('start')
confirm=(root/'confirm').exists()
if confirm:print('Enable Remote Control?',flush=True)
else:print('https://claude.ai/code/test-session',flush=True)
while True:
 if select.select([sys.stdin],[],[],0.2)[0]:
  data=os.read(sys.stdin.fileno(),4096)
  if not data:sys.exit(0)
  if b'\\x03' in data:stop()
  if confirm and b'y' in data:
   confirm=False;print('https://claude.ai/code/test-session',flush=True)
''')
fake.chmod(0o700)
env = dict(os.environ, IREMOTEAIPEEK_SERVICE_DIR=str(service),
           IREMOTEAIPEEK_CLAUDE_EXECUTABLE=str(fake))
processes = []

def write(name, value):
    p = service / name
    temp = p.with_suffix('.tmp')
    temp.write_text(json.dumps(value))
    temp.chmod(0o600)
    temp.replace(p)

def config(folder, chrome=True, permission='', spawn=''):
    write('configuration.json', dict(folder=str(folder), chrome=chrome,
          permissionMode=permission, spawnMode=spawn))

def state():
    try:
        return json.loads((service / 'status.json').read_text())
    except (OSError, ValueError):
        return {}

def wait(predicate, description, timeout=12):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        value = state()
        if predicate(value):
            return value
        time.sleep(0.08)
    raise AssertionError(description + ': ' + repr(state()))

def command(action, **fields):
    if fields:
        request = dict(action=action, instanceID=state()['instanceID'], createdAt=time.time()-978307200, **fields)
        write('commands/%020d.json' % time.monotonic_ns(), request)
    else:
        subprocess.run([str(binary), '--service-command', action], env=env,
                       check=True, capture_output=True)

def launch():
    p = subprocess.Popen([str(binary), '--service'], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    processes.append(p)
    return p

try:
    config(folder_a)
    (service / 'confirm').touch()
    daemon = launch()
    waiting = wait(lambda s: 'needsConfirmation' in s.get('status', {}), 'confirmation state')
    child = waiting['ownPID']
    command('confirm')
    wait(lambda s: 'active' in s.get('status', {}), 'confirmation forwarding')
    assert daemon.poll() is None
    assert (service.stat().st_mode & 0o777) == 0o700
    assert ((service/'status.json').stat().st_mode & 0o777) == 0o600
    assert ((service/'commands').stat().st_mode & 0o777) == 0o700
    print('PASS: PTY, confirmation, status/link, private IPC permissions')
    (service/'confirm').unlink()
    second = launch()
    second.wait(timeout=5)
    assert second.returncode != 0
    print('PASS: duplicate supervisor refused')
    subprocess.run([str(binary), '--service-status'], env=env, check=True, capture_output=True)
    assert daemon.poll() is None and state()['ownPID'] == child
    command('start')
    time.sleep(0.6)
    assert state()['ownPID'] == child
    print('PASS: client exit and repeated start keep the same child')
    config(folder_a, chrome=False, permission='plan', spawn='same-dir')
    command('restart')
    changed = wait(lambda s: s.get('ownPID') not in (None,child)
                   and 'active' in s.get('status', {}), 'restart/options')
    assert changed['runningArguments'] == ['--permission-mode','plan','--spawn','same-dir']
    child = changed['ownPID']
    config(folder_b, chrome=False, permission='plan', spawn='same-dir')
    command('changeFolder', folder=str(folder_b))
    changed = wait(lambda s: s.get('ownPID') not in (None,child)
                   and 'active' in s.get('status', {}), 'change folder')
    events = [json.loads(l) for l in (service/'events').read_text().splitlines()]
    assert [e for e in events if e['event']=='start'][-1]['cwd'] == str(folder_b.resolve())
    print('PASS: restart, permission/spawn/Chrome options and folder change')
    child = changed['ownPID']
    os.kill(child, signal.SIGKILL)
    wait(lambda s: s.get('ownPID') not in (None,child)
         and 'active' in s.get('status', {}), 'automatic recovery', timeout=15)
    print('PASS: crashed child automatically restarted')
    write('commands/stale.json', dict(action='stop', instanceID='previous-supervisor', createdAt=time.time()-978307200))
    time.sleep(0.7)
    assert state()['isRunning']
    print('PASS: commands for a previous supervisor are rejected')
    command('stop')
    wait(lambda s: not s.get('isRunning', True) and 'stopped' in s.get('status', {}), 'stop')
    daemon.terminate()
    daemon.wait(timeout=12)
    daemon = launch()
    wait(lambda s: s.get('daemonPID') == daemon.pid and 'stopped' in s.get('status', {}), 'persistent stop')
    assert not state()['isRunning']
    print('PASS: explicit stop survives supervisor restart')
    command('start')
    wait(lambda s: 'active' in s.get('status', {}), 'start after stop')
    daemon.terminate()
    daemon.wait(timeout=12)
    result = subprocess.run([str(binary),'--service-status'],env=env,capture_output=True)
    assert result.returncode != 0
    print('PASS: graceful daemon shutdown and stale status rejected')
    link = root / 'symlink-state'
    link.symlink_to(service, target_is_directory=True)
    result = subprocess.run([str(binary),'--service'], env=dict(env,IREMOTEAIPEEK_SERVICE_DIR=str(link)),capture_output=True,timeout=5)
    assert result.returncode != 0
    print('PASS: symlink IPC directory rejected')
finally:
    for p in processes:
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=12)
            except subprocess.TimeoutExpired: p.kill();p.wait()
    print('Isolated test artifacts:',root)
