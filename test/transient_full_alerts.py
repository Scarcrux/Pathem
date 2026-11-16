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
