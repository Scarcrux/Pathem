"""Exact known-findings comparison. Native RED remains native RED."""
import re

RECEIPT = re.compile(r'^LAYOUTMATRIX: (PASS|FAIL) (\S+) check(\d+)(?:\s|$)')


def failing_set(log):
    failures, seen = set(), set()
    for line in log.splitlines():
        match = RECEIPT.match(line)
        if not match:
            if line.startswith(('LAYOUTMATRIX: PASS ', 'LAYOUTMATRIX: FAIL ')):
                raise ValueError('Malformed matrix verdict')
            continue
        status, cell, check = match.groups()
        key = (cell, int(check))
        if key in seen:
            raise ValueError('Duplicate cell/check receipt: ' + str(key))
        seen.add(key)
        if status == 'FAIL':
            failures.add(key)
    return failures


def compare(log, baseline):
    expected = {}
    for entry in baseline['findings']:
        if not entry.get('id') or not entry.get('reason'):
            raise ValueError('Known findings require an ID and causal reason')
        key = (entry['cell'], entry['check'])
        if not isinstance(entry['check'], int) or entry['check'] not in {1, 2, 3, 4, 5, 7, 8}:
            raise ValueError('Setup and unresolved selection failures cannot be baselined')
        if key in expected:
            raise ValueError('Duplicate baseline cell/check')
        expected[key] = entry['id']
    actual = failing_set(log)
    new = actual - expected.keys()
    stale = expected.keys() - actual
    return not new and not stale, sorted(new), [(key, expected[key]) for key in sorted(stale)]
