from pathlib import Path
import unittest

class ReceiptStreamControls(unittest.TestCase):
    def test_transient_receipts_use_one_unbuffered_stream(self):
        root=Path(__file__).resolve().parents[1]
        for p in (root/'Sources/Pathem').glob('Transient*.swift'):
            self.assertNotIn('print(',p.read_text(),p.name+' mixes buffered and direct receipt writes')
        source=(root/'Sources/Pathem/TransientSurfaceSample.swift').read_text()
        start=source.index('    func trace(');end=source.index('    func emit(',start)
        self.assertIn('FileHandle.standardOutput.write',source[start:end])
