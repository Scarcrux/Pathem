"""Bind each modal/sensitive-surface test to the factory production actually calls."""
import hashlib
import json
from pathlib import Path
import re
from transient_inventory import mask
ROOT=Path(__file__).resolve().parents[1]

def function_source(source,name):
    code=mask(source)
    match=re.search(r'\bfunc\s+'+re.escape(name)+r'\s*\(',code)
    if not match:raise ValueError('Missing factory/caller function '+name)
    start=code.index('{',match.end());end=start+1;depth=1
    while depth:
        if code[end]=='{':depth+=1
        elif code[end]=='}':depth-=1
        end+=1
    return source[match.start():end]

def validate(root=ROOT):
    records=json.loads((root/'test/transient_factories.json').read_text())['factories']
    inventory=json.loads((root/'test/transient_inventory.json').read_text())['sites']
    ids=[r['id'] for r in records]
    if len(ids)!=len(set(ids)):raise ValueError('Duplicate factory profile')
    adapters=(root/'Sources/Pathem/TransientSurfaceFullFactories.swift').read_text()
    declarations=list(re.finditer(r'\bfactory\(\s*"(f\d+)",\s*"([^"]+)",\s*function:\s*"([^"]+)"',adapters))
    if len(declarations)!=len(records) or {m[1] for m in declarations}!=set(ids):
        raise ValueError('Factory adapter set differs from reviewed profiles')
    adapter_blocks={m[1]:adapters[m.start():declarations[i+1].start() if i+1<len(declarations) else adapters.index('    var factorySites:',m.start())] for i,m in enumerate(declarations)}
    for r in records:
        if r['site'] not in inventory or inventory[r['site']].get('class')!='A':
            raise ValueError('Unclassified factory site '+r['id'])
        source=(root/r['file']).read_text()
        body=function_source(source,r['maker'])
        if hashlib.sha256(body.encode()).hexdigest()!=r['maker_sha256']:
            raise ValueError('Production factory changed; review recipe '+r['id'])
        caller=function_source(source,r['caller'])
        if hashlib.sha256(caller.encode()).hexdigest()!=r['caller_sha256']:
            raise ValueError('Production caller/Cancel guard changed; review recipe '+r['id'])
        class_name=Path(r['file']).stem.split('+')[0]
        if not re.search(re.escape(class_name)+r'\s*\.\s*'+re.escape(r['maker'])+r'\s*\(',adapter_blocks[r['id']]):
            raise ValueError('Adapter does not call declared production factory '+r['id'])
        if not re.search(re.escape(r['maker'])+r'\s*\(',caller):
            raise ValueError('Production caller no longer uses tested factory '+r['id'])
        if not re.search(r'\b'+r['constructor']+r'\s*\(',body):
            raise ValueError('Factory construction differs '+r['id'])
    return records

if __name__=='__main__':
    rows=validate()
    print(f'FACTORIES: PASS {len(rows)} profiles, {len({r["site"] for r in rows})} A sites')

def receipt_errors(log, language, group=0, probe_one=False, only=None, root=ROOT):
    from collections import Counter
    recipes=[r for r in validate(root) if (not group or r['group']==group) and (not only or r['id']==only)]
    if probe_one: recipes=recipes[:1]
    if not recipes: return ['requested factory set is empty']
    expected={f'F-{r["id"]}-{language}-{appearance}-{size}-{name}':r
              for r in recipes for appearance in (['light'] if probe_one else ['light','dark'])
              for size in ([720] if probe_one else [720,1100])
              for name in (['short','long255'] if r['filename'] else ['short'])}
    rows=re.findall(r'^TSAMPLE: (PASS|FAIL) cell=(F-\S+) check=(\d+) ',log,re.M)
    actual={cell for _,cell,_ in rows}
    errors=[]
    if actual != expected.keys():
        errors.append(f'factory cells differ: missing={sorted(expected.keys()-actual)} extra={sorted(actual-expected.keys())}')
    counts=Counter((cell,int(check)) for _,cell,check in rows)
    for cell in actual & expected.keys():
        recipe=expected[cell]
        for check in range(9):
            wanted=9 if recipe['constructor']=='NSSavePanel' and check in (1,2,3) else 3
            if counts[cell,check]!=wanted:
                errors.append(f'factory three-cycle check set incomplete: {cell} check{check} count={counts[cell,check]} expected={wanted}')
        if ('FAIL',cell,'0') in rows:
            errors.append('factory setup failed: '+cell)
    covered=Counter(re.findall(r'^TSAMPLE: COVERED class=A site=(\S+) cell=F-',log,re.M))
    wanted=Counter()
    for r in recipes:wanted[r['site']]+=(1 if probe_one else 4)*(2 if r['filename'] else 1)
    if covered!=wanted:errors.append('factory site coverage differs from requested treatment')
    for name,check in [('startup',0),('6-binding',6)]:
        if not re.search(r'^TSAMPLE: PASS cell=predicate-'+name+r' check='+str(check)+r' ',log,re.M):
            errors.append('factory control missing or failed: '+name)
    if re.search(r'^TSAMPLE: FAIL cell=(?:factory-|predicate-)',log,re.M):
        errors.append('factory instrument control failed')
    if 'timedOut=true' in log:errors.append('factory modal inspection timed out')
    return errors
