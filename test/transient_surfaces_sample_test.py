import unittest
from transient_surfaces_sample import validate, source_digest


def transcript(remove=None, fail=None, marker=None):
    rows = []
    def row(cell, number):
        if (cell, number) != remove:
            rows.append(f'TSAMPLE: {"FAIL" if (cell, number) == fail else "PASS"} cell={cell} check={number} fixture')
    for n in range(1, 9):
        row('predicate-' + str(n), n)
    row('predicate-1-viewport', 1)
    for kind in ['rename', 'reclaim', 'conflict']:
        for n in range(1, 9):
            row('A-' + kind + '-de-light-720-short', n)
    ids = ['automation-result', 'demo-offer', 'extension-confirm', 'folder-handler-confirm',
           'mirror-result', 'path-suggestion', 'sync-result', 'tag-failure', 'toggle-failure', 'updater-unconfigured']
    for id in ids:
        for n in [1, 2, 3]:
            row('B-' + id + '-de-720', n)
    for id in ['demo-offer', 'extension-confirm', 'folder-handler-confirm']:
        for n in [4, 5, 7, 8]:
            row('B-' + id + '-de-720-lifecycle', n)
    row('B-contract', 4)
    header = 'TSAMPLE: START language=de preferred=["de"] cancel=Abbrechen pilot=true injection=clean'
    tail = f'TSAMPLE: SUMMARY cells=17 predicates=8 checks={len(rows)} failures={int(fail is not None)} seconds=1\nRESULT: {"FAIL" if fail else "PASS"} ({len(rows)-int(fail is not None)}/{len(rows)})'
    return '\n'.join([header] + ([marker] if marker else []) + rows + [tail])


class SampleReceiptControls(unittest.TestCase):
    def test_complete_clean_receipt(self):
        errors, failures = validate(transcript(), 0, 'clean', 'de', True, 'Abbrechen')
        self.assertEqual((errors, failures), ([], set()))

    def test_missing_individual_check_is_rejected(self):
        errors, _ = validate(transcript(remove=('A-conflict-de-light-720-short', 8)), 0, 'clean', 'de', True, 'Abbrechen')
        self.assertTrue(any('check coverage' in error for error in errors), errors)

    def test_delivered_injection_requires_new_named_red(self):
        log = transcript(fail=('A-rename-de-light-720-short', 1), marker='LAYOUTMATRIX: INJECT accessory-short delivered')
        reference = {'source_digest': source_digest(), 'native_exit': 0, 'preferences_unchanged': True, 'demo_removed': True, 'failures': []}
        self.assertEqual(validate(log, 1, 'accessory-short', 'de', True, 'Abbrechen', reference)[0], [])
        self.assertTrue(validate(log.replace('LAYOUTMATRIX: INJECT accessory-short', 'not delivered'), 1, 'accessory-short', 'de', True, 'Abbrechen', reference)[0])
        self.assertTrue(validate(log, 1, 'leaked-window', 'de', True, 'Abbrechen', reference)[0])

    def test_stale_source_or_already_red_target_is_rejected(self):
        pair = ('A-rename-de-light-720-short', 1)
        log = transcript(fail=pair, marker='LAYOUTMATRIX: INJECT accessory-short delivered')
        for reference in [{'source_digest': 'stale', 'native_exit': 0, 'preferences_unchanged': True, 'demo_removed': True, 'failures': []},
                          {'source_digest': source_digest(), 'native_exit': 0, 'preferences_unchanged': True, 'demo_removed': True, 'failures': [list(pair)]}]:
            self.assertTrue(validate(log, 1, 'accessory-short', 'de', True, 'Abbrechen', reference)[0])

    def test_product_red_stays_red_while_new_injection_can_discriminate(self):
        log = transcript(fail=('A-rename-de-light-720-short', 1), marker='LAYOUTMATRIX: INJECT accessory-short delivered')
        reference = {'source_digest': source_digest(), 'native_exit': 1, 'preferences_unchanged': True,
                     'demo_removed': True, 'failures': [['B-path-suggestion-de-720', 2]],
                     'errors': ['clean native verdict red: exit 1, 1 cell/check pairs']}
        self.assertEqual(validate(log, 1, 'accessory-short', 'de', True, 'Abbrechen', reference)[0], [])
        self.assertEqual(reference['native_exit'], 1)
        reference['errors'].append('predicate controls incomplete or failed')
        self.assertTrue(validate(log, 1, 'accessory-short', 'de', True, 'Abbrechen', reference)[0])

    def test_constraint_conflicts_are_never_hidden(self):
        self.assertIn('constraint-conflict log line', validate(transcript() + '\nUnable to simultaneously satisfy constraints', 0, 'clean', 'de', True, 'Abbrechen')[0])

    def test_wrong_localization_or_native_exit_is_rejected(self):
        self.assertTrue(validate(transcript(), 0, 'clean', 'de', True, 'Cancel')[0])
        self.assertTrue(validate(transcript(), 1, 'clean', 'de', True, 'Abbrechen')[0])


if __name__ == '__main__':
    unittest.main()
