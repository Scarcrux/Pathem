#!/usr/bin/env python3
"""Unit 1 only. Preserve native verdicts; validate delivered controls against a clean pilot."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import time
from layout_matrix_support import defaults_snapshot, verify_defaults

ROOT = pathlib.Path(__file__).resolve().parents[1]
LANGUAGES = ['de', 'ja', 'en', 'fr', 'es', 'zh-Hans']
CASES = {'clean': None, 'accessory-short': ('A-rename-', 1),
         'dismiss-failure': ('A-conflict-', 7), 'leaked-window': ('A-rename-', 8),
         'cancel-commits-edit': ('A-rename-', 5)}
CHECK = re.compile(r'^TSAMPLE: (PASS|FAIL) cell=(\S+) check=(\d+) ', re.M)
CONFLICT = re.compile(r'Unable to simultaneously satisfy|Unsatisfiable constraints|CONSTRAINTCONFLICT', re.I)


def source_digest():
    digest = hashlib.sha256()
    paths = (sorted((ROOT / 'Sources/Pathem').rglob('*.swift'))
             + sorted((ROOT / 'Sources/Pathem/Resources').rglob('Localizable.strings'))
             + sorted((ROOT / '.build/debug/Pathem_Pathem.bundle').rglob('Localizable.strings'))
             + [ROOT / 'test/transient_inventory.json', pathlib.Path(__file__)])
    for path in paths:
        digest.update(str(path.relative_to(ROOT)).encode())
        digest.update(path.read_bytes())
    binary = ROOT / '.build/debug/Pathem'
    if binary.is_file():
        digest.update(b'native-debug-artifact')
        with binary.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
    return digest.hexdigest()


def validate(log, code, case, language, pilot, expected_cancel, reference=None):
    errors = []
    rows = CHECK.findall(log)
    failures = {(cell, int(check)) for status, cell, check in rows if status == 'FAIL'}
    predicates = [(status, cell, check) for status, cell, check in rows if re.fullmatch(r'predicate-[1-8]', cell)]
    if len(predicates) != 8 or any(status != 'PASS' for status, _, _ in predicates):
        errors.append('predicate controls incomplete or failed')
    viewport = [(status, check) for status, cell, check in rows if cell == 'predicate-1-viewport']
    if viewport != [('PASS', '1')]:
        errors.append('viewport geometry sub-control missing or failed')
    multiplicity = [(status, check) for status, cell, check in rows if cell == 'predicate-8-multiplicity']
    if multiplicity != [('PASS', '8')]:
        errors.append('window count sub-control missing or failed')
    appearance = [(status, check) for status, cell, check in rows if cell == 'predicate-4-appearance']
    if appearance != [('PASS', '4')]:
        errors.append('appearance delivery sub-control missing or failed')
    if not re.search(r'^TSAMPLE: SUMMARY .*$', log, re.M) or not re.search(r'^RESULT: (PASS|FAIL) \(\d+/\d+\)$', log, re.M):
        errors.append('missing native terminal receipt')
    if f'TSAMPLE: START language={language} ' not in log or f'cancel={expected_cancel} ' not in log:
        errors.append('requested localization not delivered')
    a_cells = {cell for _, cell, _ in rows if cell.startswith('A-')}
    expected_a = (3 if pilot else 16) if language in ['de', 'ja'] else 0
    if len(a_cells) != expected_a or (a_cells and {c.split('-')[1] for c in a_cells} != {'rename', 'reclaim', 'conflict'}):
        errors.append(f'class A set incomplete: {len(a_cells)} expected {expected_a}')
    for cell in a_cells:
        observed = {int(check) for _, found, check in rows if found == cell}
        if not set(range(1, 9)) <= observed:
            errors.append('class A check coverage incomplete: ' + cell)
    for cell in {cell for _, cell, _ in rows if cell.startswith('B-') and cell != 'B-contract'}:
        required = {4, 5, 7, 8} if cell.endswith('-lifecycle') else {1, 2, 3}
        observed = {int(check) for _, found, check in rows if found == cell}
        if not required <= observed:
            errors.append('class B check coverage incomplete: ' + cell)
    if CONFLICT.search(log):
        errors.append('constraint-conflict log line')
    if case == 'clean':
        b = {cell for _, cell, _ in rows if cell.startswith('B-') and cell != 'B-contract' and not cell.endswith('-lifecycle')}
        behavior = {cell for _, cell, _ in rows if cell.startswith('B-') and cell.endswith('-lifecycle')}
        if len(b) != (10 if pilot else 20) or len(behavior) != ((3 if pilot else 6) if language == 'de' else 0):
            errors.append('class B structural/lifecycle sample incomplete')
        if code != 0 or failures:
            errors.append(f'clean native verdict red: exit {code}, {len(failures)} cell/check pairs')
    else:
        prefix, number = CASES[case]
        marker = 'LAYOUTMATRIX: INJECT accessory-short' if case == 'accessory-short' else 'TSAMPLE: INJECT ' + case
        if marker not in log:
            errors.append('injection was not delivered')
        target = {pair for pair in failures if pair[0].startswith(prefix) and pair[1] == number}
        if code != 1 or not target:
            errors.append('injection did not turn its named check red')
        # A clean treatment may expose a real product finding. Its native red is
        # never waived: only the *new named* corruption validates the instrument.
        valid_reference = (reference is not None and reference.get('source_digest') == source_digest()
                           and reference.get('native_exit') in (0, 1)
                           and reference.get('preferences_unchanged') is True
                           and reference.get('demo_removed') is True
                           and all(error.startswith('clean native verdict red:') for error in reference.get('errors', [])))
        if not valid_reference:
            errors.append('missing structurally complete clean pilot on the same source/artifact')
        elif target.intersection({tuple(x) for x in reference['failures']}):
            errors.append('target already failed without injection')
    return errors, failures


def run_case(case, language, pilot):
    temp = pathlib.Path(subprocess.check_output(['getconf', 'DARWIN_USER_TEMP_DIR'], text=True).strip())
    scratch = pathlib.Path(tempfile.mkdtemp(prefix='pathem-transient-sample-', dir=temp))
    before = defaults_snapshot()
    env = dict(os.environ, PATHEM_TRANSIENT_SURFACES_TEST='1', PATHEM_DEMO='1',
               PATHEM_CONFIG_DIR=str(scratch / 'config'), PATHEM_DEMO_ROOT=str(scratch / 'demo'),
               PATHEM_TRANSIENT_SURFACES_OUT=str(scratch), PATHEM_TRANSIENT_SURFACES_LANGUAGE=language,
               PATHEM_TRANSIENT_SURFACES_INVENTORY=str(ROOT / 'test/transient_inventory.json'),
               PATHEM_TRANSIENT_SURFACES_INJECT=case)
    for name in ['PATHEM_TRANSIENT_SURFACES_FOCUS', 'PATHEM_LAYOUT_MATRIX_TEST', 'PATHEM_LAYOUT_MATRIX_INJECT', 'PATHEM_TRANSIENT_INJECT_DISMISS_FAILURE', 'PATHEM_TRANSIENT_SURFACES_PILOT']:
        env.pop(name, None)
    if pilot:
        env['PATHEM_TRANSIENT_SURFACES_PILOT'] = '1'
    if case == 'accessory-short':
        env['PATHEM_LAYOUT_MATRIX_INJECT'] = case
    if case == 'dismiss-failure':
        env['PATHEM_TRANSIENT_INJECT_DISMISS_FAILURE'] = '1'
    label = f'{case}-{language}' + ('-pilot' if pilot else '')
    print('SAMPLE receipts', scratch, 'case', label, flush=True)
    started = time.monotonic()
    inputs_before = source_digest()
    try:
        run = subprocess.run([str(ROOT / '.build/debug/Pathem'), '-AppleLanguages', '(' + language + ')'], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
        log, code = run.stdout.decode(errors='replace'), run.returncode
    except subprocess.TimeoutExpired as error:
        log, code = (error.stdout or b'').decode(errors='replace'), 124
    (scratch / 'native.log').write_text(log)
    private_ok = verify_defaults(before, scratch)
    demo_removed_native = not (scratch / 'demo').exists()
    if not demo_removed_native:
        # The process has terminated/reaped. A crash cannot run its atexit cleanup;
        # remove only this runner's exact demo root while retaining failure receipts.
        demo = scratch / 'demo'
        if demo.is_dir() and not demo.is_symlink():
            shutil.rmtree(demo)
    demo_removed = not (scratch / 'demo').exists()
    expected_catalog = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(ROOT / f'Sources/Pathem/Resources/{language}.lproj/Localizable.strings')]))
    reference_path = ROOT / '.build/transient-sample-clean-de-pilot.json'
    reference = json.loads(reference_path.read_text()) if reference_path.exists() else None
    errors, failures = validate(log, code, case, language, pilot, expected_catalog['common.cancel'], reference)
    built_paths = [p for p in (ROOT / '.build/debug/Pathem_Pathem.bundle').rglob('Localizable.strings')
                   if p.parent.name.casefold() == (language + '.lproj').casefold()]
    catalog_match = False
    if len(built_paths) == 1:
        built_catalog = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(built_paths[0])]))
        catalog_match = built_catalog == expected_catalog
    if not catalog_match:
        errors.append('built localization catalog differs from reviewed source')
    inventory = json.loads((ROOT / 'test/transient_inventory.json').read_text())
    sample_keys = {key for row in inventory['sites'].values() for sample in [row.get('sample')]
                   if sample for key in [sample['message_key']] + sample['informative_keys'] + sample['button_keys']}
    if not sample_keys <= expected_catalog.keys():
        errors.append('sample localization keys missing from shipped catalog')
    if not private_ok or not demo_removed:
        errors.append('preference/demo isolation failed')
    if source_digest() != inputs_before:
        errors.append('source or native artifact changed during launch')
    receipt = dict(case=case, language=language, pilot=pilot, native_exit=code,
                   source_digest=inputs_before, failures=sorted(failures), errors=errors,
                   reference_native_exit=reference.get('native_exit') if case != 'clean' and reference else None,
                   preferences_unchanged=private_ok, catalog_matches_source=catalog_match,
                   demo_removed=demo_removed, native_demo_removed=demo_removed_native, seconds=time.monotonic()-started)
    (ROOT / f'.build/transient-sample-{label}.log').write_text(log)
    (ROOT / f'.build/transient-sample-{label}.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print('SAMPLE receipt', json.dumps(receipt), flush=True)
    for line in log.splitlines():
        if line.startswith(('TSAMPLE: FAIL', 'TSAMPLE: INJECT', 'TSAMPLE: SUMMARY', 'RESULT:')):
            print(line, flush=True)
    if not errors:
        # Keep native logs/renders, never matching preference snapshots; remove only our scratch.
        for image in scratch.glob('*.png'):
            shutil.copy2(image, ROOT / '.build' / (label+'-'+image.name))
        shutil.rmtree(scratch)
        print('SAMPLE own scratch removed; preferences compared in memory', flush=True)
    return not errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('case', choices=CASES)
    parser.add_argument('--pilot', action='store_true')
    parser.add_argument('--language', choices=LANGUAGES)
    args = parser.parse_args()
    os.umask(0o077)
    if args.case != 'clean' and not args.pilot:
        parser.error('injections are bounded pilot controls')
    languages = [args.language] if args.language else (['de'] if args.pilot else LANGUAGES)
    if args.case != 'clean' and languages != ['de']:
        parser.error('injections use the contracted German pilot')
    results = [run_case(args.case, language, args.pilot) for language in languages]
    print('RESULT: '+('PASS' if all(results) else 'FAIL')+' sample validation')
    raise SystemExit(not all(results))


if __name__ == '__main__':
    main()
