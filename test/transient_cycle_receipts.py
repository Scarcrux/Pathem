"""Exact per-check cycle and phase coverage; repeated rows cannot replace transitions."""
from collections import Counter
import re


def cycle_errors(log, cell, phases, cycle_checks, context):
    expected=Counter()
    for cycle in range(3):
        for phase in phases:
            for number in (1, 2, 3):
                expected[number, 'phase', (f'cycle{cycle}-{phase}',)]+=1
        for number in cycle_checks:
            expected[number, 'cycle', (str(cycle),)]+=1
    actual=Counter()
    for number, detail in re.findall(r'^TSAMPLE: (?:PASS|FAIL) cell='+re.escape(cell)+r' check=(\d+) ([^\n]*)$',log,re.M):
        number=int(number)
        if number in (1, 2, 3): label='phase'
        elif number in cycle_checks: label='cycle'
        else: continue
        values=tuple(re.findall(r'\b'+label+r'=(\S+)',detail))
        actual[number,label,values]+=1
    if actual!=expected:
        return [context+' exact cycle/phase checks incomplete or duplicated: '+cell]
    return []
