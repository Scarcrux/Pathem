from contextlib import redirect_stdout
import io
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
import transient_surfaces_full as full

class FullRunnerControls(unittest.TestCase):
    def setUp(self):
        self.temp=TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);(self.root/'.build').mkdir()
        self.jobs=[dict(category='mounts',language='de',group=0,only='m73',label='clean-de-full-mounts-g0-m73')]
        self.rows=[];self.native=0;self.failures=[];self.errors=[];self.calls=[];self.isolated=True
        self.baseline=self.root/'known.json';self.baseline.write_text('{"findings":[]}')
    def native_run(self,*args,**kwargs):
        if getattr(self,'cached',False):return True
        job=self.jobs[len(self.calls)];self.calls.append(job['label'])
        r=dict(launch_id=kwargs.get('launch_id'),label=job['label'],source_digest='digest',preferences_unchanged=self.isolated,
            demo_removed=True,private_domain_removed=True,catalog_matches_source=True,
            native_exit=self.native,failures=self.failures,errors=self.errors,seconds=0.1)
        p=self.root/'.build'/('transient-sample-'+job['label']+'.json');p.write_text(json.dumps(r));p.with_suffix('.log').write_text('raw native '+str(self.native))
        return not self.errors
    def execute(self,digests=None):
        self.baseline.write_text(json.dumps(dict(findings=self.rows)))
        with patch.object(full,'ROOT',self.root),patch.object(full,'coverage',return_value=dict(A_total=1,A_native=1,A_delegated=0,B_total=0)),patch.object(full,'source_digest',side_effect=digests or ['digest','digest']),patch.object(full,'run_case',side_effect=self.native_run),redirect_stdout(io.StringIO()):
            return full.run(self.root/'output',self.baseline,self.jobs)
    def finding(self):
        return dict(cell='M-fixture',check=1,id='fixture',mechanism='owned counterexample',source='fixture.swift',receipt='owned.log',render='owned.png')
    def test_clean_complete_plan(self):self.assertTrue(self.execute())
    def test_matching_known_native_red_stays_raw_red(self):
        self.native=1;self.failures=[['M-fixture',1]];self.errors=['clean native verdict red: fixture'];self.rows=[self.finding()]
        self.assertTrue(self.execute())
        r=json.loads((self.root/'output'/(self.jobs[0]['label']+'.json')).read_text());self.assertEqual(r['native_exit'],1)
    def test_unexpected_product_red_refused(self):
        self.native=1;self.failures=[['M-fixture',1]];self.errors=['clean native verdict red: fixture'];self.assertFalse(self.execute())
    def test_stale_finding_refused(self):self.rows=[self.finding()];self.assertFalse(self.execute())
    def test_instrument_error_stops_following_launch(self):
        self.jobs.append(dict(category='b',language='de',group=0,only='b03',label='clean-de-full-b-g0-b03'))
        self.errors=['requested treatment missing'];self.assertFalse(self.execute());self.assertEqual(len(self.calls),1)
    def test_preference_change_refused(self):self.isolated=False;self.assertFalse(self.execute())
    def test_source_change_refused(self):self.assertFalse(self.execute(['digest','changed']))

    def test_plan_mode_never_launches_or_creates_output(self):
        jobs=self.jobs
        with patch('sys.argv',['transient_surfaces_full.py','--plan']),patch.object(full,'plan',return_value=jobs),patch.object(full,'coverage',return_value={}),patch.object(full,'run_case',side_effect=AssertionError('GUI launch forbidden')) as native,patch.object(full,'run',side_effect=AssertionError('runner forbidden')),redirect_stdout(io.StringIO()):
            full.main()
        native.assert_not_called()
        self.assertFalse((self.root/'output').exists())
    def test_focused_run_cannot_qualify_full_baseline(self):
        with patch('sys.argv',['transient_surfaces_full.py','--surface','m39','--known-findings','unused.json']),redirect_stdout(io.StringIO()),patch('sys.stderr',io.StringIO()):
            with self.assertRaises(SystemExit) as error:full.main()
        self.assertEqual(error.exception.code,2)

    def test_cached_receipt_cannot_replace_a_fresh_launch(self):
        self.native_run()
        self.calls.clear()
        self.cached=True
        self.assertFalse(self.execute())
