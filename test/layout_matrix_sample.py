#!/usr/bin/env python3
"""Unit 1 only. Run under caffeinate and the shared native lock. No full matrix."""
import argparse
import os
import pathlib
import shutil
import re
import subprocess
import tempfile
import time
from layout_matrix_support import defaults_snapshot, verify_defaults

os.umask(0o077)

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT / '.build/debug/Pathem'
parser = argparse.ArgumentParser()
parser.add_argument('case', choices=['clean', 'terminal-collapse', 'icon-label-short', 'accessory-short'])
parser.add_argument('--full', action='store_true', help='Approved Unit 2 covering set, below150 cells/240sec')
args = parser.parse_args()
temp = pathlib.Path(subprocess.check_output(['getconf', 'DARWIN_USER_TEMP_DIR'], text=True).strip())
scratch = pathlib.Path(tempfile.mkdtemp(prefix='pathem-matrix-' + args.case + '-', dir=temp))
scratch.chmod(0o700)
print('MATRIX receipts ' + str(scratch), flush=True)


before = defaults_snapshot()
env = dict(os.environ, PATHEM_LAYOUT_MATRIX_TEST='1', PATHEM_DEMO='1',
           PATHEM_RELEASE_TEST='1', PATHEM_CONFIG_DIR=str(scratch / 'config'),
           PATHEM_DEMO_ROOT=str(scratch / 'demo'), PATHEM_LAYOUT_MATRIX_OUT=str(scratch))
if args.full:
    env['PATHEM_LAYOUT_MATRIX_FULL'] = '1'
env['PATHEM_DEMO_TORRENTS'] = '1'
env.pop('PATHEM_LAYOUT_MATRIX_INJECT', None)
if args.case != 'clean':
    env['PATHEM_LAYOUT_MATRIX_INJECT'] = args.case
started = time.monotonic()
try:
    run = subprocess.run([str(BIN)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240 if args.full else 45)
except subprocess.TimeoutExpired as error:
    (scratch / 'native.log').write_bytes(error.stdout or b'')
    assert verify_defaults(before, scratch), 'defaults changed during timed-out launch; differing dumps retained'
    raise SystemExit('RESULT: FAIL native timeout; retained private receipts')
log = run.stdout.decode(errors='replace')
(scratch / 'native.log').write_text(log)
elapsed = time.monotonic() - started
assert verify_defaults(before, scratch), 'defaults changed; differing dumps retained privately'
assert not (scratch / 'demo').exists(), 'demo root not removed'
print('MATRIX PASS preferences unchanged and demo removed')
print('MATRIX native exit ' + str(run.returncode))
print('MATRIX wall seconds %.3f' % elapsed)
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
print('MATRIX cells ' + str(len(begins)))
if args.full:
    assert len(begins) == 139 and len(set(begins)) == 139 and elapsed < 240, 'covering set/budget incomplete'
else:
    assert begins == ['default-list', 'default-icon', 'default-list-terminal'], 'not exactly the three contracted cells'
if args.case == 'clean':
    assert run.returncode == 0 and 'RESULT: PASS' in log, 'clean sample failed; no acceptance claimed'
else:
    target = {'terminal-collapse': 'default-list-terminal check1',
              'icon-label-short': 'default-icon check4',
              'accessory-short': 'rename-initial-control check2'}[args.case]
    if args.full:
        target = {'terminal-collapse': 'default-list-terminal-dark check1',
                  'icon-label-short': 'default-icon-none-dark check4',
                  'accessory-short': 'rename-initial-control check2'}[args.case]
    assert 'LAYOUTMATRIX: INJECT ' + args.case in log, 'injection not delivered'
    assert run.returncode == 1 and 'LAYOUTMATRIX: FAIL ' + target in log, 'injection did not expose expected regression'
if run.returncode == 0:
    shutil.rmtree(scratch)
    print('MATRIX own passing scratch removed; matching defaults never written')
print('RESULT: PASS validation case ' + args.case)
