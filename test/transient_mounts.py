"""Expected custom-surface treatment, independently bound to the source inventory."""
from collections import Counter
from transient_cycle_receipts import cycle_errors
import json
from pathlib import Path
import re
ROOT=Path(__file__).resolve().parents[1]

def validate(root=ROOT):
    recipes=json.loads((root/'test/transient_mounts.json').read_text())['mounts']
    inventory=json.loads((root/'test/transient_inventory.json').read_text())['sites']
    source=(root/'Sources/Pathem/TransientSurfaceFullMounts.swift').read_text()
    declared=re.findall(r'mount\(\s*"(m\d+)",\s*"([^"]+)"(, filename: true)?',source)
    observed={id:(prefix,bool(long)) for id,prefix,long in declared}
    if len(observed)!=len(declared) or {r['id'] for r in recipes}!=observed.keys():
        raise ValueError('Mount adapter IDs differ from reviewed inventory')
    for r in recipes:
        if r['site'] not in inventory or inventory[r['site']].get('class')!='A':
            raise ValueError('Unclassified mount: '+r['id'])
        prefix,long=observed[r['id']]
        if not r['site'].startswith('Sources/Pathem/'+prefix+':') or r['filename']!=long:
            raise ValueError('Mount source or filename treatment changed: '+r['id'])
        if r['id'] in {'m64','m65','m66'} and not r.get('caller_sha256'):
            raise ValueError('Confirmation caller provenance missing: '+r['id'])
        if r.get('caller_sha256'):
            from transient_factories import function_source
            import hashlib
            file=r['site'].split(':')[0]
            body=function_source((root/file).read_text(),r['caller'])
            if hashlib.sha256(body.encode()).hexdigest()!=r['caller_sha256']:
                raise ValueError('Audited confirmation caller changed: '+r['id'])
    return recipes

def receipt_errors(log, language, group, probe_one=False, only=None, root=ROOT):
    recipes=[r for r in validate(root) if (not group or r['group']==group) and (not only or r['id']==only)]
    if probe_one:recipes=recipes[:1]
    if not recipes:return ['requested mount set is empty']
    expected={f'M-{r["id"]}-{language}-{appearance}-{size}-{name}'
        for r in recipes for appearance in (['light'] if probe_one else ['light','dark'])
        for size in ([720] if probe_one else [720,1100])
        for name in (['short','long255'] if r['filename'] else ['short'])}
    rows=re.findall(r'^TSAMPLE: (PASS|FAIL) cell=(M-\S+) check=(\d+) ',log,re.M)
    actual={cell for _,cell,_ in rows}
    errors=[]
    if actual!=expected:errors.append(f'custom mount cells differ: missing={sorted(expected-actual)} extra={sorted(actual-expected)}')
    counts=Counter((cell,int(check)) for _,cell,check in rows)
    for cell in expected & actual:
        recipe=next(r for r in recipes if cell.startswith('M-'+r['id']+'-'))
        errors += cycle_errors(log,cell,['mounted']+(['content-changed'] if recipe.get('content_change') else []),[0,4,5,6,7,8],'custom mount')
        if any(counts[cell,check]!=(6 if recipe.get('content_change') and check in (1,2,3) else 3) for check in range(9)):
            errors.append('custom mount three-cycle check set incomplete: '+cell)
    covered=Counter(re.findall(r'^TSAMPLE: COVERED class=A site=(\S+) cell=M-',log,re.M))
    wanted=Counter({r['site']:(1 if probe_one else 4)*(2 if r['filename'] else 1) for r in recipes})
    if covered!=wanted:errors.append('custom mount site coverage differs from requested treatment')
    for cell in expected:
        recipe=next(r for r in recipes if cell.startswith('M-'+r['id']+'-'))
        if recipe.get('content_change'):
            delivered=re.findall(r'^TSAMPLE: PASS cell=mount-content check=0 cell='+re.escape(cell)+r' cycle=(\d+) changed-content delivered=true$',log,re.M)
            if sorted(delivered)!=['0','1','2']:errors.append('changed content delivery incomplete: '+cell)
    if re.search(r'^TSAMPLE: FAIL cell=mount-(?:setup|content|callback|work|media-delivery)',log,re.M):
        errors.append('mount fixture or changed content failed')
    if 'TSAMPLE: PASS cell=mount-metadata-control check=0 ' not in log:
        errors.append('cancel metadata control missing or failed')
    if not re.search(r'^TSAMPLE: PASS cell=predicate-startup check=0 sheets=0 ',log,re.M):
        errors.append('isolated startup state missing or failed')
    return errors
