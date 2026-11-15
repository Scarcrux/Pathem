import pathlib
import stat
import tempfile
import unittest
from unittest.mock import patch
from layout_matrix_support import verify_defaults


class PreferenceEvidenceTests(unittest.TestCase):
    def test_matching_preferences_never_written(self):
        before = {'test-domain': {'sample-key': 'fixture'}}
        with tempfile.TemporaryDirectory(prefix='pathem-matrix-control-') as directory:
            with patch('layout_matrix_support.defaults_snapshot', return_value=before):
                self.assertTrue(verify_defaults(before, directory))
            self.assertEqual(list(pathlib.Path(directory).iterdir()), [])

    def test_differing_preferences_written_privately(self):
        with tempfile.TemporaryDirectory(prefix='pathem-matrix-control-') as directory:
            with patch('layout_matrix_support.defaults_snapshot', return_value={'test-domain': {}}):
                self.assertFalse(verify_defaults({'test-domain': {'sample-key': 'fixture'}}, directory))
            paths = list(pathlib.Path(directory).iterdir())
            self.assertEqual({path.name for path in paths}, {'defaults-before.plist', 'defaults-after.plist'})
            self.assertTrue(all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in paths))


if __name__ == '__main__':
    unittest.main()
