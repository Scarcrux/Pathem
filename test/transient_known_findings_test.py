import unittest
from transient_known_findings import collect,compare

class KnownFindingsControls(unittest.TestCase):
    def finding(self,cell='M-m34-de-light-720-short',check=2):
        return dict(id='oversized-crop',cell=cell,check=check,mechanism='600pt sheet exceeds 420pt host',source='CropController.present',receipt='.build/crop.log',render='.build/crop.png')
    def receipt(self):
        result=dict(label='clean-de-full-mounts-g5',category='mounts',source_digest='same',preferences_unchanged=True,demo_removed=True,private_domain_removed=True,catalog_matches_source=True,native_exit=1,failures=[['M-m34-de-light-720-short',2]],errors=['clean native verdict red: exit 1, 1 cell/check pairs'])
        self.attach_render_evidence(result)
        return result
    def attach_render_evidence(self,receipt):
        import hashlib,uuid
        from pathlib import Path
        from tempfile import TemporaryDirectory
        from transient_render_evidence import gather_failure_renders
        from transient_render_evidence_test import png_bytes
        temp=TemporaryDirectory();self.addCleanup(temp.cleanup);root=Path(temp.name)
        launch=uuid.uuid4().hex;scratch=root/'native';scratch.mkdir()
        for cell,number in receipt['failures']:
            name=f'{cell}-check{number}.png'
            if cell.startswith('L-'):
                name=f"{cell}-{'prompt' if (receipt.get('lifecycle_disk_proof') or {}).get('prompt_seen') else 'before'}.png"
            (scratch/name).write_bytes(png_bytes())
        errors,receipt['failure_renders']=gather_failure_renders(scratch,receipt['failures'],receipt['category'],receipt.get('lifecycle_disk_proof'),root/'evidence'/launch,launch,receipt['source_digest'])
        assert not errors
        receipt['launch_id']=launch
        receipt['native_log_sha256']=hashlib.sha256(b'owned native receipt').hexdigest()
    def test_exact_baseline_matches(self):
        row=self.finding();self.assertEqual(compare({(row['cell'],row['check'])},[row]),[])
    def test_new_failure_is_red(self):
        self.assertTrue(any('NEW' in e for e in compare({('other',2)},[self.finding()])))
    def test_repaired_finding_is_stale(self):
        self.assertTrue(any('STALE' in e for e in compare(set(),[self.finding()])))
    def test_duplicate_or_unexplained_finding_is_refused(self):
        r=self.finding();self.assertTrue(compare({(r['cell'],2)},[r,r]));r['mechanism']='';self.assertTrue(compare(set(),[r]))
    def test_controls_cannot_be_baselined(self):
        for cell,check in [('predicate-3',3),('M-m01',0)]:self.assertTrue(compare({(cell,check)},[self.finding(cell,check)]))
    def test_complete_product_red_is_eligible_but_stays_native_red(self):
        r=self.receipt();errors,pairs=collect([r],[r['label']],'same');self.assertEqual(errors,[]);self.assertEqual(r['native_exit'],1);self.assertEqual(len(pairs),1)
    def test_missing_and_duplicate_plan_refused(self):
        r=self.receipt();self.assertTrue(collect([],[r['label']],'same')[0]);self.assertTrue(collect([r,r],[r['label']],'same')[0])
    def test_stale_source_and_isolation_failure_refused(self):
        r=self.receipt();self.assertTrue(collect([r],[r['label']],'changed')[0]);r['preferences_unchanged']=False;self.assertTrue(collect([r],[r['label']],'same')[0])
    def test_timeout_setup_or_constraint_error_never_eligible(self):
        for change in [{'native_exit':124},{'failures':[['M-m01',0]]},{'errors':['constraint-conflict log line']},{'errors':['custom mount three-cycle check set incomplete']}]:
            r={**self.receipt(),**change};self.assertTrue(collect([r],[r['label']],'same')[0])
    def test_real_quit_exit_is_separate_from_parent_verdict(self):
        r=self.receipt();r.update(category='lifecycle',native_exit=0,failures=[['L-quit',5]],lifecycle_disk_proof=dict(mode='quit',will_terminate=True,quit_requested=True,edited_before=True,save_control=True,lost_without_prompt=True,disk_annotations=0,prompt_seen=False,before_sha256='actual-hash',post_reap_sha256='actual-hash'),errors=['lifecycle product verdict red: lost unsaved markup'])
        self.attach_render_evidence(r)
        self.assertEqual(collect([r],[r['label']],'same')[0],[])

    def test_malformed_pair_and_incomplete_quit_proof_refused(self):
        r=self.receipt();r['failures']=[['missing check']]
        self.assertTrue(collect([r],[r['label']],'same')[0])
        r=self.receipt();r.update(category='lifecycle',native_exit=0,lifecycle_disk_proof={'mode':'quit'})
        self.assertTrue(collect([r],[r['label']],'same')[0])
