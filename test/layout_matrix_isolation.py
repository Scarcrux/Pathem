#!/usr/bin/env python3
"""Bounded real-launch isolation checks. Never installs or writes owner defaults."""
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT / '.build/debug/Pathem'
TEMP = pathlib.Path(subprocess.check_output(['getconf', 'DARWIN_USER_TEMP_DIR'], text=True).strip())
scratch = pathlib.Path(tempfile.mkdtemp(prefix='pathem-matrix-isolation-', dir=TEMP))
scratch.chmod(0o700)
print('ISOLATION receipts ' + str(scratch), flush=True)
swift = subprocess.check_output(['xcrun', '--toolchain', 'XcodeDefault', '--find', 'swift'], text=True).strip()
os.environ['PATH'] = str(pathlib.Path(swift).parent) + os.pathsep + os.environ['PATH']


def defaults_snapshot():
    result = {}
    for domain in ['Pathem', 'com.scarcrux.pathem']:
        output = subprocess.run(['/usr/bin/defaults', 'export', domain, '-'], capture_output=True)
        values = plistlib.loads(output.stdout) if output.returncode == 0 else {}
        # Check the entire domain, not just the keys currently known to be written.
        result[domain] = values
    return result


before = defaults_snapshot()
(scratch / 'defaults-before.plist').write_bytes(plistlib.dumps(before))
base = dict(os.environ, PATHEM_CONFIG_DIR=str(scratch / 'config'), PATHEM_RELEASE_TEST='1')
base.pop('PATHEM_LAYOUT_MATRIX_TEST', None)
for label, root in [('outside', '/Applications/pathem-demo-refused'), ('existing', str(scratch))]:
    env = dict(base, PATHEM_DEMO='1', PATHEM_SITE_SHOT='terminal', PATHEM_DEMO_ROOT=root)
    run = subprocess.run([str(BIN)], env=env, capture_output=True, timeout=15)
    assert run.returncode == 64 and b'automation demo root must be a new directory' in run.stdout, label
    print('ISOLATION PASS refused ' + label + ' demo root')

run = subprocess.run([str(ROOT / 'test/e2e/run.sh'), '--configuration-root-guards', str(BIN),
                      'PATHEM_LAYOUT_MATRIX_TEST'], capture_output=True, timeout=20)
(scratch / 'guards.log').write_bytes(run.stdout + run.stderr)
assert run.returncode == 0 and b'RESULT: PASS (2/2)' in run.stdout
print('ISOLATION PASS missing and unsafe config roots refused (2/2)')

demo = scratch / 'demo'
capture = scratch / 'terminal.png'
env = dict(base, PATHEM_DEMO='1', PATHEM_DEMO_ROOT=str(demo), PATHEM_SITE_SHOT='terminal',
           PATHEM_SITE_OUT=str(capture), PATHEM_SITE_SETTLE='4')
run = subprocess.run([str(BIN)], env=env, capture_output=True, timeout=40)
(scratch / 'launch.log').write_bytes(run.stdout + run.stderr)
assert run.returncode == 0, 'site-shot launch failed; see private receipt'
receipts = run.stdout.decode().splitlines()
for action in ['used', 'removed']:
    paths = [line.split('DEMOISOLATION: ' + action + ' ', 1)[1] for line in receipts
             if line.startswith('DEMOISOLATION: ' + action + ' ')]
    assert len(paths) == 1 and pathlib.Path(paths[0]).resolve() == demo.resolve()
assert not demo.exists() and capture.stat().st_size > 1000
print('ISOLATION PASS unique demo root delivered and removed; terminal capture delivered')
after = defaults_snapshot()
(scratch / 'defaults-after.plist').write_bytes(plistlib.dumps(after))
assert before == after, 'defaults changed; before/after dumps retained privately'
print('ISOLATION PASS complete before/after defaults domains unchanged')
print('RESULT: PASS isolation; receipts ' + str(scratch))
