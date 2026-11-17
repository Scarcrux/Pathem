"""Exact invocation plan and inventory coverage for transient Unit 2."""
from pathlib import Path
import json
from transient_inventory import scan, validate as validate_inventory, validate_attachments, validate_standard_menus, render
from transient_mounts import validate as validate_mounts
from transient_factories import validate as validate_factories
from transient_full_alerts import validate as validate_alerts
from transient_catalogs import shipped_languages, A_LANGUAGES
ROOT = Path(__file__).resolve().parents[1]


def plan(root=ROOT):
    mounts = validate_mounts(root)
    factories = validate_factories(root)
    validate_alerts(root)
    jobs = []
    def add(category, language, group=0, only=None):
        label = f'clean-{language}-full-{category}-g{group}' + ('-' + only if only else '')
        jobs.append(dict(category=category, language=language, group=group, only=only, label=label))
    for language in A_LANGUAGES:
        add('core', language)
        for group in sorted({row['group'] for row in mounts}): add('mounts', language, group)
        for group in sorted({row['group'] for row in factories}): add('factories', language, group)
    for language in shipped_languages(root): add('b', language)
    for mode in ['close', 'quit']: add('lifecycle', 'de', only=mode)
    return jobs


def classify_coverage(inventory, mounts, factories, special):
    a = {key for key, row in inventory.items() if row.get('class') == 'A'}
    b = {key for key, row in inventory.items() if row.get('class') == 'B'}
    adapters = {row['site'] for row in mounts + factories}
    core = {row['site'] for row in special if row['coverage'] == 'core'}
    delegated = {row['site'] for row in special if row['coverage'] == 'task2'}
    if (core | delegated | adapters) != a:
        raise ValueError('A coverage missing or unclassified: ' + repr(sorted(a ^ (core | delegated | adapters))))
    if adapters & (core | delegated) or core & delegated:
        raise ValueError('special A coverage overlaps adapters')
    if len(special) != len(core | delegated): raise ValueError('special A coverage duplicated')
    if any(not row.get('reason') for row in special): raise ValueError('delegated/core reason missing')
    return dict(A_total=len(a), A_native=len(adapters | core), A_delegated=len(delegated), B_total=len(b))


def coverage(root=ROOT):
    manifest = json.loads((root/'test/transient_inventory.json').read_text())
    builders, sites, ignored = scan(root, manifest['exclude_files'])
    errors = validate_inventory(builders, sites, manifest) + validate_attachments(root, builders, manifest) + validate_standard_menus(root, manifest)
    if ignored != manifest.get('ignored_counts', {}): errors.append('stale explicit DEBUG exclusion counts')
    if (root/'docs/TRANSIENT_INVENTORY.md').read_text() != render(builders, sites, ignored, manifest): errors.append('stale inventory table')
    if errors: raise ValueError('inventory gate: '+repr(errors))
    from transient_core_receipts import core_sites
    core_sites(root)  # Refuse stale delegation or disconnected core adapters before any launch.
    special = json.loads((root/'test/transient_full_special_sites.json').read_text())['sites']
    return classify_coverage(manifest['sites'], validate_mounts(root), validate_factories(root), special)


def focused_plan(surface_ids, root=ROOT):
    """Development-only subsets; never used to claim complete coverage."""
    families = {}
    for category, recipes in [('mounts', validate_mounts(root)),
                              ('factories', validate_factories(root)),
                              ('b', validate_alerts(root))]:
        for row in recipes:
            families[row['id']] = category
    if len(surface_ids) != len(set(surface_ids)):
        raise ValueError('duplicate surface selection')
    unknown = set(surface_ids) - families.keys()
    if unknown: raise ValueError('unknown surface IDs: '+repr(sorted(unknown)))
    jobs = []
    for surface in surface_ids:
        category = families[surface]
        languages = shipped_languages(root) if category == 'b' else A_LANGUAGES
        for language in languages:
            jobs.append(dict(category=category, language=language, group=0, only=surface,
                             label=f'clean-{language}-full-{category}-g0-{surface}'))
    return jobs
