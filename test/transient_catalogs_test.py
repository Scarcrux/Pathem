"""Catalog discovery and bounded CLI controls. Every native runner is mocked."""
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from transient_catalogs import shipped_languages
import transient_full_plan as plans
import transient_pair_universe as universe

EXPECTED=['de','ja','en','fr','es','zh-Hans','it','ko','nl','pt-BR','ru','zh-Hant']


class CatalogScopeControls(unittest.TestCase):
    def catalogs(self,root,languages):
        for language in languages:
            path=Path(root)/'Sources/Pathem/Resources'/(language+'.lproj')
            path.mkdir(parents=True,exist_ok=True)
            (path/'Localizable.strings').write_text('')
    def test_real_shipped_catalogs_are_all_discovered_in_stable_order(self):
        self.assertEqual(shipped_languages(),EXPECTED)
    def test_discovery_is_dynamic_and_ignores_non_catalog_directories(self):
        with TemporaryDirectory() as temp:
            self.catalogs(temp,['zz','en','ko','de'])
            empty=Path(temp)/'Sources/Pathem/Resources'/'unused.lproj';empty.mkdir()
            self.assertEqual(shipped_languages(temp),['de','en','ko','zz'])
            self.catalogs(temp,['fr'])
            self.assertEqual(shipped_languages(temp),['de','en','fr','ko','zz'])
    def test_no_catalogs_refuses_before_planning(self):
        with TemporaryDirectory() as temp:
            with self.assertRaisesRegex(ValueError,'no shipped'):shipped_languages(temp)
    def test_full_plan_has_all_twelve_B_catalogs_and_unchanged_A_axes(self):
        mounts=[dict(id='m'+str(n),group=n) for n in range(1,11)]
        factories=[dict(id='f'+str(n),group=n) for n in range(1,7)]
        with patch.object(plans,'validate_mounts',return_value=mounts),patch.object(plans,'validate_factories',return_value=factories),patch.object(plans,'validate_alerts',return_value=[]):
            jobs=plans.plan()
        self.assertEqual(len(jobs),48)
        self.assertEqual([j['language'] for j in jobs if j['category']=='b'],EXPECTED)
        self.assertEqual({j['language'] for j in jobs if j['category'] in {'core','mounts','factories'}},{'de','ja'})
        universe.validate_jobs(jobs)
    def test_focused_B_uses_all_catalogs_and_focused_A_stays_de_ja(self):
        with patch.object(plans,'validate_mounts',return_value=[dict(id='m1')]),patch.object(plans,'validate_factories',return_value=[]),patch.object(plans,'validate_alerts',return_value=[dict(id='b1')]):
            self.assertEqual([j['language'] for j in plans.focused_plan(['b1'])],EXPECTED)
            self.assertEqual([j['language'] for j in plans.focused_plan(['m1'])],['de','ja'])
    def test_universe_and_admission_accept_new_B_catalogs(self):
        for language in EXPECTED:
            job=dict(category='b',language=language,group=0,only='b1',label=f'clean-{language}-full-b-g0-b1')
            universe.validate_jobs([job])
            with patch.object(universe,'validate_alerts',return_value=[dict(id='b1',sheet=False)]):
                pairs=universe.planned_pairs([job])
            self.assertEqual(pairs,{(f'B-b1-{language}-{size}',check) for size in [720,1100] for check in [1,2,3]})
    def test_noncontracted_A_language_is_refused(self):
        for category in ['core','mounts','factories']:
            job=dict(category=category,language='ru',group=0,only=None,label=f'clean-ru-full-{category}-g0')
            with self.assertRaisesRegex(ValueError,'class A'):universe.validate_jobs([job])
            with self.assertRaisesRegex(ValueError,'class A'):universe.planned_pairs([job])


class FocusedCLIControls(unittest.TestCase):
    def cli(self,*arguments):
        # Invoke the actual parser in a subprocess with a canary in place of
        # native admission. A guard regression can never launch AppKit here.
        code='''import json,sys
sys.path.insert(0,sys.argv.pop(1))
import transient_surfaces_sample as sample
import transient_full_alerts,transient_factories,transient_mounts
transient_full_alerts.validate=lambda:[dict(id="b1")]
transient_factories.validate=lambda:[dict(id="f01",group=1)]
transient_mounts.validate=lambda:[dict(id="m12",group=2)]
def fake(*args,**kwargs):
 print('CANARY-RUN-CASE '+str(args[1]),flush=True)
 return True
sample.run_case=fake
sys.argv=['transient_surfaces_sample.py']+sys.argv[1:]
sample.main()
'''
        return subprocess.run([sys.executable,'-c',code,str(Path(__file__).resolve().parent),*arguments],capture_output=True,text=True,timeout=10)
    def test_only_requires_explicit_language_before_any_native_admission(self):
        for arguments in [('clean','--only','m12'),('clean','--full','--set','mounts','--only','m12'),('clean','--full','--set','b','--only','b1')]:
            result=self.cli(*arguments)
            self.assertEqual(result.returncode,2,result.stdout+result.stderr)
            self.assertIn('--only requires explicit --language',result.stderr)
            self.assertNotIn('CANARY-RUN-CASE',result.stdout)
    def test_empty_only_cannot_fall_back_to_an_entire_family(self):
        for surface in ['', '   ']:
            result=self.cli('clean','--full','--set','mounts','--only',surface,'--language','de')
            self.assertEqual(result.returncode,2,result.stdout+result.stderr)
            self.assertIn('nonempty surface ID',result.stderr)
            self.assertNotIn('CANARY-RUN-CASE',result.stdout)
    def test_only_without_full_cannot_run_the_unfiltered_unit1_sample(self):
        result=self.cli('clean','--only','m12','--language','de')
        self.assertEqual(result.returncode,2,result.stdout+result.stderr)
        self.assertIn('--only requires --full',result.stderr)
        self.assertNotIn('CANARY-RUN-CASE',result.stdout)
    def test_only_with_explicit_new_B_language_admits_exactly_one_canary(self):
        result=self.cli('clean','--full','--set','b','--only','b1','--language','ru')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(result.stdout.count('CANARY-RUN-CASE'),1)
        self.assertIn('CANARY-RUN-CASE ru',result.stdout)
    def test_default_full_A_is_only_de_ja_and_pilot_only_de(self):
        result=self.cli('clean','--full','--set','mounts')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual([x for x in result.stdout.splitlines() if x.startswith('CANARY')],['CANARY-RUN-CASE de','CANARY-RUN-CASE ja'])
        pilot=self.cli('clean','--full','--set','core','--pilot')
        self.assertEqual(pilot.returncode,0,pilot.stdout+pilot.stderr)
        self.assertEqual([x for x in pilot.stdout.splitlines() if x.startswith('CANARY')],['CANARY-RUN-CASE de'])
    def test_only_cannot_be_ignored_by_default_or_core_family(self):
        for family in ['all','core']:
            result=self.cli('clean','--full','--set',family,'--only','m12','--language','de')
            self.assertEqual(result.returncode,2,result.stdout+result.stderr)
            self.assertNotIn('CANARY-RUN-CASE',result.stdout)
    def test_only_unknown_or_wrong_group_refuses_before_native(self):
        for selection in [('unknown','0'),('m12','1')]:
            result=self.cli('clean','--full','--set','mounts','--only',selection[0],'--group',selection[1],'--language','de')
            self.assertEqual(result.returncode,2,result.stdout+result.stderr)
            self.assertNotIn('CANARY-RUN-CASE',result.stdout)
        good=self.cli('clean','--full','--set','mounts','--only','m12','--language','de')
        self.assertEqual(good.returncode,0,good.stdout+good.stderr)
        self.assertEqual(good.stdout.count('CANARY-RUN-CASE'),1)
    def test_lifecycle_requires_explicit_mode_and_contracted_language(self):
        for arguments in [(),('--only','unknown','--language','de'),('--only','close','--language','ja')]:
            result=self.cli('clean','--full','--set','lifecycle',*arguments)
            self.assertEqual(result.returncode,2,result.stdout+result.stderr)
            self.assertNotIn('CANARY-RUN-CASE',result.stdout)
        good=self.cli('clean','--full','--set','lifecycle','--only','close','--language','de')
        self.assertEqual(good.returncode,0,good.stdout+good.stderr)
        self.assertEqual(good.stdout.count('CANARY-RUN-CASE'),1)

    def test_unknown_language_and_new_A_language_refuse_without_native(self):
        for language in ['unknown','ru']:
            result=self.cli('clean','--full','--set','mounts','--only','m12','--language',language)
            self.assertEqual(result.returncode,2,result.stdout+result.stderr)
            self.assertNotIn('CANARY-RUN-CASE',result.stdout)


if __name__=='__main__':unittest.main()
