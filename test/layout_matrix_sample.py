#!/usr/bin/env python3
"""Bounded sample or reviewed covering set. Native exits are retained verbatim."""
import argparse
import os
import pathlib
import shutil
import re
import subprocess
import tempfile
import time
import json
from layout_matrix_support import defaults_snapshot, verify_defaults
from layout_matrix_baseline import compare

os.umask(0o077)

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT / '.build/debug/Pathem'
parser = argparse.ArgumentParser()
parser.add_argument('case', choices=['clean', 'terminal-collapse', 'icon-label-short', 'accessory-short'])
parser.add_argument('--full', action='store_true', help='Approved Unit 2 covering set, below150 cells/240sec')
parser.add_argument('--known-findings', type=pathlib.Path, help='Exact reviewed cell/check/ID baseline; rejects new and stale failures')
args = parser.parse_args()
if args.known_findings and (not args.full or args.case != 'clean' or not args.known_findings.is_file()):
    parser.error('known findings require a reviewed existing file and the full clean case')
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
    assert len(begins) == 134 and len(set(begins)) == 134 and elapsed < 240, 'covering set/budget incomplete'
else:
    assert begins == ['default-list', 'default-icon', 'default-list-terminal'], 'not exactly the three contracted cells'
if args.case == 'clean':
    if args.known_findings:
        assert run.returncode in (0, 1) and re.search(r'^RESULT: (PASS|FAIL) \(\d+/\d+\)$', log, re.M), 'invalid native terminal result'
        matched, new, stale = compare(log, json.loads(args.known_findings.read_text()))
        for cell, check in new:
            print('BASELINE NEW %s check%s' % (cell, check))
        for (cell, check), finding in stale:
            print('BASELINE STALE %s %s check%s' % (finding, cell, check))
        assert matched, 'known findings differ; native red preserved, see new/stale receipts'
        print('BASELINE MATCH; native exit remains ' + str(run.returncode))
    else:
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
