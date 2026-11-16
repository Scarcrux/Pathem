import hashlib,json
from pathlib import Path
import tempfile,unittest
from transient_markup_lifecycle import evaluate

class MarkupLifecycleEvidenceControls(unittest.TestCase):
    def fixture(self,mode='quit',saved=False,prompt=False):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup);root=Path(temp.name);directory=root/'markup-lifecycle';directory.mkdir()
        data=b'saved fixture' if saved else b'original fixture';(directory/'owned-unsaved.pdf').write_bytes(data)
        digest=lambda x:hashlib.sha256(x).hexdigest()
        witness=dict(mode=mode,fixture='owned-unsaved.pdf',edited_before=True,save_control=True,delegate='PathemAppDelegate',before_sha256=digest(b'original fixture'),after_sha256=digest(data),disk_annotations=1 if saved else 0,prompt_seen=prompt,quit_requested=mode=='quit',will_terminate=mode=='quit',window_closed=mode=='close',stage='will-terminate' if mode=='quit' else 'closed')
        (directory/'witness.json').write_text(json.dumps(witness))
        log='TLIFECYCLE: QUIT-REQUEST mode=quit\nTLIFECYCLE: WILL-TERMINATE mode=quit'
        return root,directory,witness,log
    def test_lost_edits_on_natural_quit_are_red(self):
        root,_,_,log=self.fixture();errors,findings,_=evaluate(log,0,'quit',root)
        self.assertEqual(errors,[]);self.assertEqual(findings,{('L-quit',5)})
    def test_real_autosave_would_disprove_loss(self):
        root,_,_,log=self.fixture(saved=True);self.assertEqual(evaluate(log,0,'quit',root)[:2],([],set()))
    def test_prompt_would_disprove_no_guard(self):
        root,_,_,log=self.fixture(prompt=True);self.assertEqual(evaluate(log,0,'quit',root)[:2],([],set()))
    def test_close_is_separate_evidence(self):
        root,_,_,log=self.fixture('close');self.assertEqual(evaluate(log,1,'close',root)[:2],([],{('L-close',5)}))
    def test_changed_post_reap_bytes_are_refused(self):
        root,d,_,log=self.fixture();(d/'owned-unsaved.pdf').write_bytes(b'late change')
        self.assertTrue(evaluate(log,0,'quit',root)[0])
    def test_signal_exit_is_not_quit_evidence(self):
        root,_,_,log=self.fixture();self.assertTrue(evaluate(log,-15,'quit',root)[0])
    def test_missing_native_termination_is_refused(self):
        root,_,_,_=self.fixture();self.assertTrue(evaluate('',0,'quit',root)[0])
    def test_missing_treatment_and_control_are_refused(self):
        for key in ['edited_before','save_control']:
            root,d,w,log=self.fixture();w[key]=False;(d/'witness.json').write_text(json.dumps(w))
            self.assertTrue(evaluate(log,0,'quit',root)[0])
