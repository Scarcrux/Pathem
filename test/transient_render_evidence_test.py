import hashlib
from pathlib import Path
import struct
from tempfile import TemporaryDirectory
import unittest
import zlib
from transient_render_evidence import png_evidence,gather_failure_renders,verify_failure_renders


def png_bytes(raw=b'\x00\xff\x00\x00\xff'):
    def chunk(kind,payload):return struct.pack('>I',len(payload))+kind+payload+struct.pack('>I',zlib.crc32(kind+payload)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',1,1,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')

class FailureRenderControls(unittest.TestCase):
    def setUp(self):
        self.temp=TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        self.scratch=self.root/'native';self.scratch.mkdir();self.launch='a'*32
        self.image=self.scratch/'M-fixture-check1.png';self.image.write_bytes(png_bytes())
        self.artifacts=self.root/'evidence'/self.launch
    def collect(self,failures=None,category='mounts',proof=None):
        return gather_failure_renders(self.scratch,failures or {('M-fixture',1)},category,proof,self.artifacts,self.launch,'same')
    def receipt(self,evidence):
        return dict(failures=[['M-fixture',1]],failure_renders=evidence,launch_id=self.launch,source_digest='same',native_log_sha256=hashlib.sha256(b'raw native').hexdigest())
    def test_valid_PNG_retained_and_bound_to_receipt(self):
        errors,rows=self.collect();self.assertEqual(errors,[])
        self.assertEqual(png_evidence(self.image)['width'],1)
        self.assertEqual(verify_failure_renders(self.receipt(rows),'raw native'),[])
        self.image.unlink();self.assertEqual(verify_failure_renders(self.receipt(rows),'raw native'),[])
    def test_missing_capture_refused(self):
        self.image.unlink();errors,rows=self.collect();self.assertTrue(errors);self.assertEqual(rows,[])
    def test_bad_signature_and_corrupt_checksum_refused(self):
        for data in [b'not PNG',png_bytes()[:-1]+b'X']:
            self.image.write_bytes(data)
            with self.assertRaises(ValueError):png_evidence(self.image)
    def test_valid_checksums_do_not_hide_corrupt_image_data(self):
        for raw in [b'',b'\x05\xff\x00\x00\xff',b'\x00\xff']:
            self.image.write_bytes(png_bytes(raw))
            with self.assertRaises(ValueError):png_evidence(self.image)
    def test_truncated_PNG_refused(self):
        self.image.write_bytes(png_bytes()[:-12])
        with self.assertRaises(ValueError):png_evidence(self.image)
    def test_symlink_capture_refused(self):
        original=self.scratch/'original.png';self.image.rename(original);self.image.symlink_to(original)
        self.assertTrue(self.collect()[0])
    def test_retained_bytes_modified_after_collection_refused(self):
        _,rows=self.collect();Path(rows[0]['path']).write_bytes(b'corrupt')
        self.assertTrue(verify_failure_renders(self.receipt(rows)))
    def test_missing_duplicate_and_foreign_evidence_refused(self):
        _,rows=self.collect()
        for evidence in [[],rows+rows,[{**rows[0],'launch_id':'b'*32}],[{**rows[0],'source_digest':'other'}]]:
            self.assertTrue(verify_failure_renders(self.receipt(evidence)))
    def test_native_receipt_hash_is_checked(self):
        _,rows=self.collect();self.assertTrue(verify_failure_renders(self.receipt(rows),'other native log'))
    def test_control0_cannot_require_or_supply_product_evidence(self):
        errors,rows=self.collect({('predicate-1',1),('M-fixture',0)})
        self.assertEqual((errors,rows),([],[]))
    def test_lifecycle_uses_actual_before_render_with_treatment_proof(self):
        (self.scratch/'L-quit-before.png').write_bytes(png_bytes())
        proof=dict(mode='quit',edited_before=True,prompt_seen=False)
        errors,rows=self.collect({('L-quit',5)},'lifecycle',proof);self.assertEqual(errors,[])
        r={**self.receipt(rows),'category':'lifecycle','failures':[['L-quit',5]],'lifecycle_disk_proof':proof}
        self.assertEqual(verify_failure_renders(r),[])
        r['lifecycle_disk_proof']={**proof,'edited_before':False};self.assertTrue(verify_failure_renders(r))
    def test_lifecycle_missing_before_capture_refused(self):
        errors,_=self.collect({('L-quit',5)},'lifecycle',dict(mode='quit',edited_before=True,prompt_seen=False))
        self.assertTrue(errors)
