"""Harmless Python children and mocked awake assertions only. Never launches AppKit."""
from contextlib import suppress
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest.mock import Mock,patch
from transient_process import awake_hold,run_owned_native

class OwnedProcessControls(unittest.TestCase):
    def test_success_returns_raw_output_and_exit(self):
        r=run_owned_native([sys.executable,'-c','print("owned harmless child")'],os.environ.copy(),5)
        self.assertEqual(r.stdout,b'owned harmless child\n');self.assertEqual(r.returncode,0);self.assertIsNone(r.instrument_error)
    def test_failure_keeps_raw_nonzero_exit(self):
        r=run_owned_native([sys.executable,'-c','raise SystemExit(7)'],os.environ.copy(),5)
        self.assertEqual(r.returncode,7);self.assertIsNone(r.instrument_error)
    def test_timeout_terminates_and_reaps_owned_child(self):
        previous={s:signal.getsignal(s) for s in [signal.SIGTERM,signal.SIGINT,signal.SIGHUP,signal.SIGALRM]}
        r=run_owned_native([sys.executable,'-c','import time;time.sleep(30)'],os.environ.copy(),0.2)
        self.assertIn(r.returncode,[-signal.SIGTERM,-signal.SIGKILL]);self.assertIn('timeout',r.instrument_error)
        self.assertEqual(previous,{s:signal.getsignal(s) for s in previous})
    def test_ignoring_term_uses_bounded_kill_and_reap(self):
        code='import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);print("ready",flush=True);time.sleep(30)'
        r=run_owned_native([sys.executable,'-c',code],os.environ.copy(),1)
        self.assertIn(b'ready',r.stdout);self.assertEqual(r.returncode,-signal.SIGKILL);self.assertIn('timeout',r.instrument_error)
    def test_interrupted_supervisor_retires_exact_native_child(self):
        # The worker below is our owned helper process, never an owner application.
        module_dir=str(Path(__file__).resolve().parent)
        worker='''import json,os,sys
sys.path.insert(0,sys.argv[1])
from transient_process import run_owned_native
r=run_owned_native([sys.executable,'-c','import time;print("native-ready",flush=True);time.sleep(30)'],os.environ.copy(),30)
print(json.dumps(dict(code=r.returncode,error=r.instrument_error)),flush=True)
'''
        # Its native stdout is supervised/captured, so signal only after an explicit
        # worker-side Popen wrapper confirms a child handle exists.
        worker=worker.replace('from transient_process import run_owned_native','''import transient_process
real=transient_process.subprocess.Popen
def announce(*a,**kw):
 p=real(*a,**kw);print("worker-ready",flush=True);return p
transient_process.subprocess.Popen=announce
from transient_process import run_owned_native''')
        p=subprocess.Popen([sys.executable,'-u','-c',worker,module_dir],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            self.assertEqual(p.stdout.readline().strip(),'worker-ready')
            p.terminate()
            out,err=p.communicate(timeout=10)
            self.assertEqual(p.returncode,0,err)
            r=json.loads(out.strip());self.assertIn(r['code'],[-signal.SIGTERM,-signal.SIGKILL]);self.assertIn('signal 15',r['error'])
        finally:
            if p.poll() is None:p.kill();p.communicate(timeout=5)
    def test_awake_assertion_is_mocked_and_scoped_to_python_pid(self):
        p=Mock();p.wait.return_value=0
        with patch('transient_process.subprocess.Popen',return_value=p) as start:
            with awake_hold():pass
        argv=start.call_args.args[0];self.assertEqual(argv,['/usr/bin/caffeinate','-d','-i','-w',str(os.getpid())])
        p.terminate.assert_called_once();p.wait.assert_called_once_with(timeout=2)
    def test_awake_cleanup_also_runs_on_exception_without_real_caffeinate(self):
        p=Mock();p.wait.return_value=0
        with patch('transient_process.subprocess.Popen',return_value=p):
            with self.assertRaises(ValueError):
                with awake_hold():raise ValueError('counterexample')
        p.terminate.assert_called_once();p.wait.assert_called_once_with(timeout=2)
