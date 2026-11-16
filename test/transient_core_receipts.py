"""Exact core variants, content-change phases, cycles and production-site receipts."""
from collections import Counter
import json
from pathlib import Path
import re
from transient_inventory import mask
from transient_factories import function_source
ROOT = Path(__file__).resolve().parents[1]
IDENTITIES = {
    ('BrowserViewController+Rename.swift', 'presentSheet'): 'rename',
    ('CleanupController.swift', 'presentDeleteNowAlert'): 'reclaim',
    ('BrowserViewController+Transfers.swift', 'ask'): 'conflict',
    ('CursorConfirm.swift', 'show'): 'conflict',
}


def core_sites(root=ROOT):
    inventory=json.loads((root/'test/transient_inventory.json').read_text())['sites']
    special=json.loads((root/'test/transient_full_special_sites.json').read_text())['sites']
    result={'rename':[], 'reclaim':[], 'conflict':[]}
    identities=[]
    for row in special:
        if row['coverage']!='core':continue
        site=row['site'];parts=site.split(':');identity=(Path(parts[0]).name,parts[-1])
        if identity not in IDENTITIES or inventory.get(site,{}).get('class')!='A':
            raise ValueError('unreviewed core production site: '+site)
        identities.append(identity);result[IDENTITIES[identity]].append(site)
    if Counter(identities)!=Counter(IDENTITIES.keys()):
        raise ValueError('core production site set differs from reviewed four sites')
    source=(root/'Sources/Pathem/TransientSurfaceSample.swift').read_text()
    body=mask(function_source(source,'runSurface'))
    for pattern in [r'\bRenameDialogController\s*\(',r'\bbrowser\s*\.\s*presentSheet\s*\(',
                    r'\bCleanupController\s*\.\s*deleteNowAlert\s*\(',r'\bCleanupController\s*\.\s*presentDeleteNowAlert\s*\(',
                    r'\bbrowser\s*\.\s*askConflictResolution\s*\(',r'\bsuggestion\s*\.\s*debugDeliver\s*\(',r'\bsuggestion\s*\.\s*debugFail\s*\(']:
        if not re.search(pattern,body):raise ValueError('core production construction/transition missing: '+pattern)
    return result


def cells(language,pilot=False):
    if language not in ['de','ja']:return {}
    return {f'A-{kind}-{language}-{appearance}-{size}-{name}':kind
            for kind in ['rename','reclaim','conflict']
            for appearance in (['light'] if pilot else ['light','dark'])
            for size in ([720] if pilot else [720,1100])
            for name in (['short','long255'] if kind=='rename' and not pilot else ['short'])}


def receipt_errors(log,language,pilot=False,root=ROOT):
    try:sites=core_sites(root)
    except (KeyError,ValueError) as error:return ['core source contract failed: '+str(error)]
    expected=cells(language,pilot)
    rows=re.findall(r'^TSAMPLE: (PASS|FAIL) cell=(A-\S+) check=(\d+) ([^\n]*)$',log,re.M)
    actual={cell for _,cell,_,_ in rows}
    errors=[]
    if actual!=expected.keys():errors.append('core cell set differs from requested variants: missing='+repr(sorted(expected.keys()-actual))+' extra='+repr(sorted(actual-expected.keys())))
    for cell in expected.keys() & actual:
        kind=expected[cell];want=Counter()
        for cycle in range(3):
            phases=[f'cycle{cycle}-initial']
            if kind=='rename':
                phases += [f'cycle{cycle}-suggestion',f'cycle{cycle}-failure']
                if cycle==1:phases.append('cycle1-typed')
            for phase in phases:
                for number in [1,2,3]:want[number,'phase',phase]+=1
            for number in [4,5,6,7,8]:want[number,'cycle',str(cycle)]+=1
        observed=Counter()
        for _,found,number,detail in rows:
            if found!=cell:continue
            number=int(number)
            label='phase' if number in (1,2,3) else 'cycle'
            match=re.search(r'\b'+label+r'=(\S+)',detail)
            observed[number,label,match[1] if match else None]+=1
        if observed!=want:errors.append('core exact cycle/phase checks incomplete or duplicated: '+cell)
    claimed=Counter(re.findall(r'^TSAMPLE: CORE-SITE cell=(\S+) cycle=(\d+) site=(\S+)$',log,re.M))
    wanted=Counter((cell,str(cycle),site) for cell,kind in expected.items() for cycle in range(3) for site in sites[kind])
    if claimed!=wanted:errors.append('core production-site coverage differs from requested treatment')
    return errors
