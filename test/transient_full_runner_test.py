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
        from transient_render_evidence import gather_failure_renders
        from transient_render_evidence_test import png_bytes
        import hashlib
        launch_id=kwargs.get('launch_id') or '0'*32
        scratch=self.root/'fake-native'/launch_id;scratch.mkdir(parents=True,exist_ok=True)
        for cell,number in self.failures:
            (scratch/f'{cell}-check{number}.png').write_bytes(png_bytes())
        render_errors,r['failure_renders']=gather_failure_renders(scratch,self.failures,'mounts',None,self.root/'artifacts'/launch_id,launch_id,'digest')
        assert not render_errors
        native_log='raw native '+str(self.native)
        r['native_log_sha256']=hashlib.sha256(native_log.encode()).hexdigest()
        p=self.root/'.build'/('transient-sample-'+job['label']+'.json');p.write_text(json.dumps(r));p.with_suffix('.log').write_text(native_log)
        return not self.errors
    def execute(self,digests=None):
        self.baseline.write_text(json.dumps(dict(findings=self.rows)))
        with patch.object(full,'ROOT',self.root),patch.object(full,'coverage',return_value=dict(A_total=1,A_native=1,A_delegated=0,B_total=0)),patch.object(full,'source_digest',side_effect=digests or ['digest','digest']),patch.object(full,'run_case',side_effect=self.native_run),patch.object(full,'planned_pairs',return_value={('M-fixture',1)}),redirect_stdout(io.StringIO()):
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

    def test_baseline_missing_refused_before_any_native_launch(self):
        with patch.object(full,'run_case',side_effect=AssertionError('native forbidden')) as native:
            with self.assertRaises(OSError):full.run(self.root/'output',self.root/'missing.json',self.jobs)
        native.assert_not_called();self.assertFalse((self.root/'output').exists())
    def test_malformed_baselines_refused_before_any_native_launch(self):
        candidates=['{', '{}', '{"findings":{}}', '{"findings":[{"cell":"M-x","check":true}]}',
                    '{"findings":[{"cell":"M-x","check":1}]}']
        for text in candidates:
            self.baseline.write_text(text)
            with patch.object(full,'run_case',side_effect=AssertionError('native forbidden')) as native:
                with self.assertRaises((ValueError,TypeError,KeyError)):
                    full.run(self.root/'output',self.baseline,self.jobs)
            native.assert_not_called();self.assertFalse((self.root/'output').exists())
    def test_baseline_bytes_are_pinned_in_plan_and_summary(self):
        import hashlib
        self.assertTrue(self.execute())
        expected=hashlib.sha256(self.baseline.read_bytes()).hexdigest()
        for name in ['plan.json','summary.json']:
            self.assertEqual(json.loads((self.root/'output'/name).read_text())['baseline_sha256'],expected)
    def test_baseline_is_not_reread_after_native_work(self):
        original=self.native_run
        def mutate(*args,**kwargs):
            value=original(*args,**kwargs)
            self.baseline.write_text('{')
            return value
        self.native_run=mutate
        self.assertTrue(self.execute())

    def test_whole_budget_refuses_job_before_native_admission(self):
        with patch.object(full,'RUN_BUDGET_SECONDS',1):
            self.assertFalse(self.execute())
        self.assertEqual(self.calls,[])
        summary=json.loads((self.root/'output'/'summary.json').read_text())
        self.assertTrue(any('budget exhausted before job admission' in e for e in summary['errors']))
    def test_remaining_budget_is_passed_as_bounded_native_timeout(self):
        original=self.native_run;observed=[]
        def capture(*args,**kwargs):
            observed.append(kwargs)
            return original(*args,**kwargs)
        self.native_run=capture
        with patch.object(full,'RUN_BUDGET_SECONDS',90),patch.object(full.time,'monotonic',return_value=100):
            self.assertTrue(self.execute())
        self.assertEqual(observed[0]['native_timeout'],30)
        self.assertEqual(observed[0]['deadline'],190)
    def test_elapsed_job_stops_following_native_admission(self):
        self.jobs.append(dict(category='b',language='de',group=0,only='b03',label='clean-de-full-b-g0-b03'))
        clock=[100.0];original=self.native_run
        def advance(*args,**kwargs):
            value=original(*args,**kwargs);clock[0]+=21
            return value
        self.native_run=advance
        with patch.object(full,'RUN_BUDGET_SECONDS',80),patch.object(full.time,'monotonic',side_effect=lambda:clock[0]):
            self.assertFalse(self.execute())
        self.assertEqual(len(self.calls),1)

    def test_impossible_baseline_cell_or_check_refused_before_launch(self):
        for cell,check in [('M-m999-de-light-720-short',1),('B-b03-de-720',8)]:
            self.baseline.write_text(json.dumps({'findings':[{**self.finding(),'cell':cell,'check':check}]}))
            with patch.object(full,'planned_pairs',return_value={('B-b03-de-720',1)}),patch.object(full,'run_case',side_effect=AssertionError('native forbidden')) as native:
                with self.assertRaisesRegex(ValueError,'outside selected plan'):
                    full.run(self.root/'output',self.baseline,self.jobs)
            native.assert_not_called()
            self.assertFalse((self.root/'output').exists())

    def test_bad_baseline_starts_neither_awake_nor_native_child(self):
        self.baseline.write_text('{')
        with patch.object(full,'awake_hold',side_effect=AssertionError('awake child forbidden')) as awake,patch.object(full,'run_case',side_effect=AssertionError('native forbidden')) as native:
            with self.assertRaises(ValueError):full.run(self.root/'output',self.baseline,self.jobs,awake=True)
        awake.assert_not_called();native.assert_not_called()


    def test_empty_duplicate_or_noncanonical_plan_refused_before_side_effects(self):
        job=self.jobs[0]
        cases=[[],[job,job],[{**job,'label':'cached-name'}],[{**job,'group':True}]]
        for jobs in cases:
            with patch.object(full,'awake_hold',side_effect=AssertionError('awake forbidden')) as awake,patch.object(full,'run_case',side_effect=AssertionError('native forbidden')) as native:
                with self.assertRaises(ValueError):full.run(self.root/'output',self.baseline,jobs,awake=True)
            awake.assert_not_called();native.assert_not_called()
            self.assertFalse((self.root/'output').exists())
    def test_empty_baseline_still_validates_selected_surfaces_before_side_effects(self):
        self.baseline.write_text('{"findings":[]}')
        with patch.object(full,'planned_pairs',side_effect=ValueError('unknown planned surface')),patch.object(full,'awake_hold',side_effect=AssertionError('awake forbidden')) as awake,patch.object(full,'run_case',side_effect=AssertionError('native forbidden')) as native:
            with self.assertRaisesRegex(ValueError,'unknown planned surface'):
                full.run(self.root/'output',self.baseline,self.jobs,awake=True)
        awake.assert_not_called();native.assert_not_called()
        self.assertFalse((self.root/'output').exists())
