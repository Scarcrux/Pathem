#!/usr/bin/env python3
"""Count AppKit constraint conflicts in one demo launch of the debug app.

AppKit reports an unsatisfiable layout through the unified log, not stderr, so a
plain capture of the app's output never contains the report. OS_ACTIVITY_DT_MODE
mirrors the log to stderr with the constraint list, which is what this reads.
"""
import argparse
import os
import pathlib
import re
import shutil
import subprocess
import tempfile

os.umask(0o077)

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT / '.build/debug/Pathem'
CONFLICT = re.compile(r'Conflicting constraints detected')
OWNER = re.compile(r'NSAutoresizingMaskLayoutConstraint:\S+ \S+ \S+ (\S+?):0x\w+\.(\w+) == (\d+)')

parser = argparse.ArgumentParser()
parser.add_argument('--shot', default='list', help='PATHEM_SITE_SHOT composition to stage')
parser.add_argument('--binary', type=pathlib.Path, default=BIN)
args = parser.parse_args()

temp = pathlib.Path(subprocess.check_output(['getconf', 'DARWIN_USER_TEMP_DIR'], text=True).strip())
scratch = pathlib.Path(tempfile.mkdtemp(prefix='pathem-conflicts-', dir=temp))
env = dict(os.environ, PATHEM_DEMO='1', PATHEM_CONFIG_DIR=str(scratch / 'config'),
           PATHEM_SITE_SHOT=args.shot, PATHEM_SITE_OUT=str(scratch / 'shot.png'),
           PATHEM_SITE_SETTLE='3', OS_ACTIVITY_DT_MODE='YES')
try:
    run = subprocess.run([str(args.binary)], env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, timeout=45)
except subprocess.TimeoutExpired:
    raise SystemExit('RESULT: FAIL native timeout; receipts in ' + str(scratch))
out = run.stdout.decode(errors='replace')
err = run.stderr.decode(errors='replace')
(scratch / 'stderr.log').write_text(err)

# The treatment was delivered: the composition rendered, and the log mirror is live
# (AppKit always writes at least one line through it during a launch).
assert run.returncode == 0 and 'SITE SHOT' in out, 'site shot did not render'
assert re.search(r'^\d{4}-\d\d-\d\d .*Pathem\S*\[\d+:\d+\]', err, re.M), 'log mirror delivered nothing'

blocks = err.split('Conflicting constraints detected')[1:]
owners = {}
for block in blocks:
    found = OWNER.search(block.split('Will attempt to recover')[0])
    key = '%s.%s == %s' % found.groups() if found else 'no frame-managed view'
    owners[key] = owners.get(key, 0) + 1
print('CONFLICTS total %d in shot %s' % (len(blocks), args.shot))
for key, count in sorted(owners.items()):
    print('CONFLICTS %4d frame-managed %s' % (count, key))
if blocks:
    raise SystemExit('RESULT: FAIL %d constraint conflicts; log in %s' % (len(blocks), scratch))
shutil.rmtree(scratch)
print('RESULT: PASS no constraint conflicts')
