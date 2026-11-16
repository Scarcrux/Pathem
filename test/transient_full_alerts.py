"""Audited Class B fixture provenance. Missing/stale sites or sources fail closed."""
import hashlib
import json
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

def validate(root=ROOT):
    inventory = json.loads((root/'test/transient_inventory.json').read_text())['sites']
    recipes = json.loads((root/'test/transient_full_alerts.json').read_text())['alerts']
    expected = {k for k,v in inventory.items() if v.get('class') == 'B'}
    sites = [v['site'] for v in recipes]
    if len(sites) != len(set(sites)) or set(sites) != expected:
        raise ValueError('Full B recipe sites differ from classified inventory')
    for recipe in recipes:
        site = recipe['site']
        if recipe['builder'] not in inventory[site]['builders']:
            raise ValueError('Builder provenance differs: '+site)
        file,line,*_ = recipe['builder'].split(':')
        presentation_line = int(site.split(':')[1])
        source = (root/file).read_text().splitlines()
        fragment = '\n'.join(source[int(line)-1:presentation_line])
        if hashlib.sha256(fragment.encode()).hexdigest() != recipe['source_sha256']:
            raise ValueError('Alert source changed; review fixture: '+site)
        if not recipe.get('fixture'):
            raise ValueError('Missing runtime fixture rationale: '+site)
    return recipes

if __name__ == '__main__':
    rows=validate()
    print(f'FULL B PROVENANCE: PASS {len(rows)} sites, {sum(r["sheet"] for r in rows)} sheet sites')

def receipt_errors(log, language, root=ROOT, only=None):
    from collections import Counter
    import re
    recipes=[r for r in validate(root) if only is None or r['id']==only]
    if not recipes:return ['requested full B set is empty']
    expected={f'B-{r["id"]}-{language}-{size}':r for r in recipes for size in [720,1100]}
    lifecycle={cell+'-lifecycle':r for cell,r in expected.items() if language=='de' and r['sheet']}
    all_cells=expected.keys()|lifecycle.keys()
    rows=re.findall(r'^TSAMPLE: (PASS|FAIL) cell=(B-\S+) check=(\d+) ',log,re.M)
    actual={cell for _,cell,_ in rows};errors=[]
    if actual!=all_cells:errors.append(f'full B cells differ: missing={sorted(all_cells-actual)} extra={sorted(actual-all_cells)}')
    counts=Counter((cell,int(check)) for _,cell,check in rows)
    for cell in actual&all_cells:
        expected_counts={n:3 for n in range(1,9)} if cell in lifecycle else {n:1 for n in range(4)}
        observed={n:c for (found,n),c in counts.items() if found==cell}
        if observed!=expected_counts:errors.append('full B structural/lifecycle counts incomplete: '+cell)
        if ('FAIL',cell,'0') in rows:errors.append('full B setup failed: '+cell)
    covered=Counter(re.findall(r'^TSAMPLE: COVERED class=B site=(\S+) ',log,re.M))
    if covered!=Counter({r['site']:2 for r in recipes}):errors.append('full B site coverage differs')
    sites=re.findall(r'^TSAMPLE: SITE cell=(\S+) site=(\S+) builder=(\S+)',log,re.M)
    wanted=Counter((cell,r['site'],r['builder']) for cell,r in expected.items())
    if Counter(sites)!=wanted:errors.append('full B builder provenance differs')
    if not re.search(r'^TSAMPLE: PASS cell=full-B-contract check=0 ',log,re.M):errors.append('full B inventory control missing or failed')
    return errors
