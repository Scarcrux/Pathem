#!/usr/bin/env python3
"""Unit 1 only. Preserve native verdicts; validate delivered controls against a clean pilot."""
import argparse
from collections import Counter
import hashlib
import json
import os
import pathlib
import plistlib
import uuid
import re
import shutil
import subprocess
import tempfile
import time
from transient_deadline import bounded_native_timeout, validate_native_timeout
from transient_process import run_owned_native
from transient_catalogs import shipped_languages, A_LANGUAGES
from layout_matrix_support import defaults_snapshot, verify_defaults

ROOT = pathlib.Path(__file__).resolve().parents[1]
CASES = {'clean': None, 'accessory-short': ('A-rename-', 1),
         'dismiss-failure': ('A-conflict-', 7), 'leaked-window': ('A-rename-', 8),
         'cancel-commits-edit': ('A-rename-', 5)}
CHECK = re.compile(r'^TSAMPLE: (PASS|FAIL) cell=(\S+) check=(\d+) ', re.M)
CONFLICT = re.compile(r'Unable to simultaneously satisfy|Unsatisfiable constraints|CONSTRAINTCONFLICT', re.I)


def source_digest():
    from transient_input_manifest import digest
    return digest(ROOT)


def validate(log, code, case, language, pilot, expected_cancel, reference=None, full=False, category="all"):
    errors = []
    rows = CHECK.findall(log)
    failures = {(cell, int(check)) for status, cell, check in rows if status == 'FAIL'}
    predicates = [(status, cell, check) for status, cell, check in rows if re.fullmatch(r'predicate-[1-8]', cell)]
    expected_predicates = Counter({(f'predicate-{n}', str(n)): 1 for n in range(1, 9)})
    if Counter((cell, check) for _, cell, check in predicates) != expected_predicates or any(status != 'PASS' for status, _, _ in predicates):
        errors.append('predicate controls incomplete or failed')
    if ('PASS', 'predicate-file-opening', '0') not in rows:
        errors.append('file-opening interception control missing or failed')
    if ('PASS', 'predicate-3-system', '3') not in rows:
        errors.append('system-panel ownership sub-control missing or failed')
    viewport = [(status, check) for status, cell, check in rows if cell == 'predicate-1-viewport']
    if viewport != [('PASS', '1')]:
        errors.append('viewport geometry sub-control missing or failed')
    multiplicity = [(status, check) for status, cell, check in rows if cell == 'predicate-8-multiplicity']
    if multiplicity != [('PASS', '8')]:
        errors.append('window count sub-control missing or failed')
    appearance = [(status, check) for status, cell, check in rows if cell == 'predicate-4-appearance']
    if appearance != [('PASS', '4')]:
        errors.append('appearance delivery sub-control missing or failed')
    if category != 'lifecycle' and (not re.search(r'^TSAMPLE: SUMMARY .*$', log, re.M) or not re.search(r'^RESULT: (PASS|FAIL) \(\d+/\d+\)$', log, re.M)):
        errors.append('missing native terminal receipt')
    if f'TSAMPLE: START language={language} ' not in log or f'cancel={expected_cancel} ' not in log:
        errors.append('requested localization not delivered')
    a_cells = {cell for _, cell, _ in rows if cell.startswith('A-')}
    expected_a = (3 if pilot else 16) if language in ['de', 'ja'] and category not in ('b', 'mounts', 'factories', 'lifecycle') else 0
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
    if full:
        for phase in ['start', 'end']:
            if ('PASS', 'predicate-external-' + phase, '0') not in rows:
                errors.append('external provider isolation missing or failed: ' + phase)
    if category == 'mounts':
        if ('PASS', 'predicate-6-binding', '6') not in rows:
            errors.append('native default-binding positive/negative control missing or failed')
        mount_cells = {cell for _, cell, _ in rows if cell.startswith('M-')}
        if not mount_cells or any(cell.startswith('B-') for _, cell, _ in rows):
            errors.append('requested custom mount treatment was not delivered')
        for cell in mount_cells:
            if not set(range(9)) <= {int(check) for _, found, check in rows if found == cell}:
                errors.append('custom mount check coverage incomplete: ' + cell)
    if full and category in ('all', 'core'):
        from transient_core_receipts import receipt_errors
        errors += receipt_errors(log, language, pilot)
    for cell, check in [('predicate-1-tooltip', 1), ('predicate-1-popup', 1), ('predicate-1-empty-alert', 1), ('predicate-4-presentation', 4)]:
        matches = [(status, int(number)) for status, found, number in rows if found == cell]
        if matches != [('PASS', check)]: errors.append('required subcontrol missing or failed: '+cell)
    if CONFLICT.search(log):
        errors.append('constraint-conflict log line')
    if case == 'clean':
        b = {cell for _, cell, _ in rows if cell.startswith('B-') and cell != 'B-contract' and not cell.endswith('-lifecycle')}
        behavior = {cell for _, cell, _ in rows if cell.startswith('B-') and cell.endswith('-lifecycle')}
        if category not in ('core', 'mounts', 'factories', 'lifecycle') and not (full and 'TSAMPLE: B-SUBSET' in log) and (len(b) != (94 if full else 10 if pilot else 20) or len(behavior) != ((2 * sum(r['sheet'] for r in __import__('transient_full_alerts').validate()) if full else 3 if pilot else 6) if language == 'de' else 0)):
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


def run_case(case, language, pilot, full=False, category="all", group=0, probe_one=False, only=None, launch_id=None, native_timeout=180, deadline=None):
    native_timeout = validate_native_timeout(native_timeout)
    launch_id = launch_id or uuid.uuid4().hex
    temp = pathlib.Path(subprocess.check_output(['getconf', 'DARWIN_USER_TEMP_DIR'], text=True).strip())
    scratch = pathlib.Path(tempfile.mkdtemp(prefix='pathem-transient-sample-', dir=temp))
    before = defaults_snapshot()
    env = dict(os.environ, PATHEM_TRANSIENT_SURFACES_TEST='1', PATHEM_DEMO='1',
               PATHEM_CONFIG_DIR=str(scratch / 'config'), PATHEM_DEMO_ROOT=str(scratch / 'demo'),
               PATHEM_TRANSIENT_SURFACES_OUT=str(scratch), PATHEM_TRANSIENT_SURFACES_LANGUAGE=language,
               PATHEM_TRANSIENT_SURFACES_INVENTORY=str(ROOT / 'test/transient_inventory.json'),
               PATHEM_TRANSIENT_SURFACES_INJECT=case)
    if full:
        env.update(PATHEM_TRANSIENT_SURFACES_GROUP=str(group), PATHEM_TRANSIENT_SURFACES_SET=category, PATHEM_TRANSIENT_SURFACES_FULL="1", PATHEM_TRANSIENT_FULL_ALERTS=str(ROOT / "test/transient_full_alerts.json"))
        env["PATHEM_TRANSIENT_FACTORIES"] = str(ROOT / "test/transient_factories.json")
    else:
        env.pop("PATHEM_TRANSIENT_SURFACES_FULL", None)
    for name in ['PATHEM_TRANSIENT_SURFACES_FOCUS', 'PATHEM_LAYOUT_MATRIX_TEST', 'PATHEM_LAYOUT_MATRIX_INJECT', 'PATHEM_TRANSIENT_INJECT_DISMISS_FAILURE', 'PATHEM_TRANSIENT_SURFACES_PILOT']:
        env.pop(name, None)
    if only:
        env['PATHEM_TRANSIENT_SURFACES_ONLY'] = only
    else:
        env.pop('PATHEM_TRANSIENT_SURFACES_ONLY', None)
    if probe_one:
        env["PATHEM_TRANSIENT_SURFACES_PROBE_ONE"] = "1"
    else:
        env.pop("PATHEM_TRANSIENT_SURFACES_PROBE_ONE", None)
    if full and category == 'mounts' and (not only or only == 'm74'):
        from transient_media_fixture import prepare
        env['PATHEM_TRANSIENT_MEDIA_FIXTURE'] = str(prepare(scratch))
    if pilot:
        env['PATHEM_TRANSIENT_SURFACES_PILOT'] = '1'
    if case == 'accessory-short':
        env['PATHEM_LAYOUT_MATRIX_INJECT'] = case
    if case == 'dismiss-failure':
        env['PATHEM_TRANSIENT_INJECT_DISMISS_FAILURE'] = '1'
    label = f'{case}-{language}' + (f'-full-{category}-g{group}' + ('-pilot' if pilot else '') + ('-' + only if only else '') + ('-probe' if probe_one else '') if full else '-pilot' if pilot else '')
    print('SAMPLE receipts', scratch, 'case', label, flush=True)
    started = time.monotonic()
    inputs_before = source_digest()
    executable = ROOT / '.build/debug/Pathem'
    private_domain = None
    if full:
        # AppKit panels can save frame/navigation keys even when cancelled. Give
        # the test process its own application domain before any AppKit object
        # exists. No owner domain is redirected, restored or written.
        private_domain = 'io.pathem.transient.fixture.' + uuid.uuid4().hex
        from transient_app_bundle import dependency_paths, prepare_bundle
        dependencies = dependency_paths(subprocess.check_output(['otool', '-L', str(executable)], text=True))
        executable = prepare_bundle(scratch, executable, private_domain, dependencies)
        env['PATHEM_TRANSIENT_PRIVATE_DOMAIN'] = private_domain
    native_started = False
    allowed_timeout = None
    native_instrument_error = None
    try:
        launch = [str(executable), '-AppleLanguages', '(' + language + ')']
        if full:
            launch += ['-pathem.demoOffered', 'YES', '-pathem.fdaGuideDismissed', 'YES']
        # Packaging and input hashing consumed wall time. Recompute here,
        # immediately before launch, and leave the same reserve for cleanup.
        allowed_timeout = bounded_native_timeout(native_timeout, deadline=deadline)
        if allowed_timeout is None:
            log, code = 'TRANSIENT DEADLINE: no native process started; cleanup reserve reached\n', 124
        else:
            native_started = True
            run = run_owned_native(launch, env, allowed_timeout)
            log, code = run.stdout.decode(errors='replace'), run.returncode
            native_instrument_error = run.instrument_error
    except subprocess.TimeoutExpired as error:
        log, code = (error.stdout or b'').decode(errors='replace'), 124
    private_domain_removed = True
    if private_domain:
        from transient_app_bundle import clear_private_domain
        private_domain_removed = clear_private_domain(private_domain)
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
    reference_path = ROOT / ('.build/transient-sample-clean-de-full-core-g0-pilot.json' if full else '.build/transient-sample-clean-de-pilot.json')
    reference = json.loads(reference_path.read_text()) if reference_path.exists() else None
    errors, failures = validate(log, code, case, language, pilot, expected_catalog['common.cancel'], reference, full, category)
    if native_instrument_error:
        errors.append(native_instrument_error)
    if not native_started:
        errors.append('whole-run budget exhausted before native launch; no process started')
    if private_domain and 'TSAMPLE: DOMAIN ' + private_domain not in log:
        errors.append('private application preference domain was not delivered')
    if not private_domain_removed:
        errors.append('owned private preference domain was not removed')
    if category == 'mounts':
        from transient_mounts import receipt_errors
        errors += receipt_errors(log, language, group, probe_one, only)
    if full and category in ('all', 'b'):
        from transient_full_alerts import receipt_errors
        errors += receipt_errors(log, language, only=only)
    if category == 'factories':
        from transient_factories import receipt_errors
        errors += receipt_errors(log, language, group, probe_one, only)
    lifecycle_proof = None
    if category == 'lifecycle':
        from transient_markup_lifecycle import evaluate
        evidence_errors, evidence_findings, lifecycle_proof = evaluate(log, code, only, scratch)
        errors += evidence_errors
        failures |= evidence_findings
        if evidence_findings:
            errors.append('lifecycle product verdict red: unsaved markup lost without a prompt')
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
    from transient_render_evidence import gather_failure_renders
    failure_renders = []
    try:
        render_errors, failure_renders = gather_failure_renders(
            scratch, failures, category, lifecycle_proof,
            ROOT / '.build/transient-render-evidence' / launch_id, launch_id, inputs_before)
        errors += render_errors
    except (OSError, ValueError) as error:
        errors.append('failure render evidence: retention failed: ' + str(error))
    receipt = dict(failure_renders=failure_renders, native_log_sha256=hashlib.sha256(log.encode()).hexdigest(), native_instrument_error=native_instrument_error, native_started=native_started, native_timeout=allowed_timeout, launch_id=launch_id, label=label, only=only, case=case, language=language, pilot=pilot, full=full, category=category, group=group, probe_one=probe_one, private_domain_removed=private_domain_removed, native_exit=code,
                   source_digest=inputs_before, failures=sorted(failures), errors=errors,
                   reference_native_exit=reference.get('native_exit') if case != 'clean' and reference else None,
                   preferences_unchanged=private_ok, catalog_matches_source=catalog_match, lifecycle_disk_proof=lifecycle_proof,
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
    parser.add_argument('--full', action='store_true')
    parser.add_argument('--set', choices=['all', 'core', 'b', 'mounts', 'factories', 'lifecycle'], default='all')
    parser.add_argument('--language', choices=shipped_languages(ROOT))
    parser.add_argument('--group', type=int, default=0)
    parser.add_argument('--probe-one', action='store_true')
    parser.add_argument('--only')
    args = parser.parse_args()
    if args.only is not None and args.language is None:
        parser.error('--only requires explicit --language to keep a focused run bounded')
    if args.only is not None and (not args.only.strip() or not args.full):
        parser.error('--only requires --full and a nonempty surface ID')
    if args.full and args.set in {'all','core','mounts','factories'} and args.language and args.language not in A_LANGUAGES:
        parser.error('full class A variants use de or ja; use --set b for another shipped catalog')
    if args.only is not None:
        if args.set not in {'mounts','factories','b','lifecycle'}:
            parser.error('--only requires an explicit surface family via --set')
        if args.set == 'lifecycle':
            valid = args.only in {'close','quit'} and args.language == 'de' and args.group == 0
        else:
            module = {'mounts':'transient_mounts','factories':'transient_factories','b':'transient_full_alerts'}[args.set]
            recipes = __import__(module).validate()
            valid = any(row['id'] == args.only and
                (args.group == 0 or (args.set != 'b' and row.get('group') == args.group))
                for row in recipes)
        if not valid:
            parser.error('--only surface does not match the selected family, group or lifecycle language')
    if args.set == 'lifecycle' and args.only is None:
        parser.error('lifecycle checks require explicit --only close or --only quit and --language de')
    os.umask(0o077)
    if args.full:
        __import__("transient_full_alerts").validate()
        __import__("transient_factories").validate()
        if args.pilot and args.set != 'core':
            parser.error("a full pilot is allowed only for the bounded core controls")
    if args.case != 'clean' and not args.pilot:
        parser.error('injections are bounded pilot controls')
    languages = [args.language] if args.language else (['de'] if args.pilot else
        list(A_LANGUAGES) if args.full and args.set in {'all','core','mounts','factories'} else shipped_languages(ROOT))
    if args.case != 'clean' and languages != ['de']:
        parser.error('injections use the contracted German pilot')
    results = [run_case(args.case, language, args.pilot, args.full, args.set, args.group, args.probe_one, args.only) for language in languages]
    print('RESULT: '+('PASS' if all(results) else 'FAIL')+' sample validation')
    raise SystemExit(not all(results))


if __name__ == '__main__':
    main()
