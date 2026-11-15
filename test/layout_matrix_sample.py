#!/usr/bin/env python3
"""Unit 1 only. Run under caffeinate and the shared native lock. No full matrix."""
import argparse
import os
import pathlib
import plistlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT / '.build/debug/Pathem'
parser = argparse.ArgumentParser()
parser.add_argument('case', choices=['clean', 'terminal-collapse', 'icon-label-short', 'accessory-short'])
args = parser.parse_args()
temp = pathlib.Path(subprocess.check_output(['getconf', 'DARWIN_USER_TEMP_DIR'], text=True).strip())
scratch = pathlib.Path(tempfile.mkdtemp(prefix='pathem-matrix-' + args.case + '-', dir=temp))
scratch.chmod(0o700)
print('MATRIX receipts ' + str(scratch), flush=True)


def defaults_snapshot():
    snapshot = {}
    for domain in ['Pathem', 'com.scarcrux.pathem']:
        run = subprocess.run(['/usr/bin/defaults', 'export', domain, '-'], capture_output=True)
        snapshot[domain] = plistlib.loads(run.stdout) if run.returncode == 0 else {}
    return snapshot


before = defaults_snapshot()
(scratch / 'defaults-before.plist').write_bytes(plistlib.dumps(before))
env = dict(os.environ, PATHEM_LAYOUT_MATRIX_TEST='1', PATHEM_DEMO='1',
           PATHEM_RELEASE_TEST='1', PATHEM_CONFIG_DIR=str(scratch / 'config'),
           PATHEM_DEMO_ROOT=str(scratch / 'demo'), PATHEM_LAYOUT_MATRIX_OUT=str(scratch))
env.pop('PATHEM_LAYOUT_MATRIX_INJECT', None)
if args.case != 'clean':
    env['PATHEM_LAYOUT_MATRIX_INJECT'] = args.case
try:
    run = subprocess.run([str(BIN)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
except subprocess.TimeoutExpired as error:
    (scratch / 'native.log').write_bytes(error.stdout or b'')
    raise SystemExit('RESULT: FAIL native timeout; retained private receipts')
log = run.stdout.decode(errors='replace')
(scratch / 'native.log').write_text(log)
after = defaults_snapshot()
(scratch / 'defaults-after.plist').write_bytes(plistlib.dumps(after))
assert before == after, 'defaults changed; private dumps retained'
assert not (scratch / 'demo').exists(), 'demo root not removed'
print('MATRIX PASS preferences unchanged and demo removed')
print('MATRIX native exit ' + str(run.returncode))
for line in log.splitlines():
    if line.startswith(('LAYOUTMATRIX:', 'RESULT:')):
        print(line)

# Constraint conflicts are checked against the complete process stream, including
# startup and sheet presentation outside the three cells. Never waive logged failures.
cell = 'startup'
conflicts = []
for line in log.splitlines():
    if line.startswith('LAYOUTMATRIX: BEGIN '):
        cell = line.split('BEGIN ', 1)[1]
    if re.search(r'Unable to simultaneously satisfy constraints|Unable to activate constraint', line):
        conflicts.append((cell, line))
for cell, line in conflicts:
    print('LAYOUTMATRIX: FAIL ' + cell + ' check5 constraint-conflict ' + line)
assert not conflicts, 'AppKit constraint conflict; captures and log retained'
controls = [line for line in log.splitlines() if re.match(r'LAYOUTMATRIX: (PASS|FAIL) predicate-', line)]
assert len(controls) == 15 and all(': PASS ' in line for line in controls), 'predicate controls failed or missing'
begins = re.findall(r'^LAYOUTMATRIX: BEGIN (.+)$', log, re.M)
assert begins == ['default-list', 'default-icon', 'default-list-terminal'], 'not exactly the three contracted cells'
if args.case == 'clean':
    assert run.returncode == 0 and 'RESULT: PASS' in log, 'clean sample failed; no acceptance claimed'
else:
    target = {'terminal-collapse': 'default-list-terminal check1',
              'icon-label-short': 'default-icon check4',
              'accessory-short': 'rename-initial-control check2'}[args.case]
    assert 'LAYOUTMATRIX: INJECT ' + args.case in log, 'injection not delivered'
    assert run.returncode == 1 and 'LAYOUTMATRIX: FAIL ' + target in log, 'injection did not expose expected regression'
print('RESULT: PASS validation case ' + args.case)
