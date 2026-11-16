"""Supervise only the captured native fixture child and its private session.

No foreign process discovery/signals. Parent death by SIGKILL cannot run Python
cleanup; ordinary TERM/INT/HUP/ALRM during the native wait are handled here.
"""
from contextlib import contextmanager
from dataclasses import dataclass
import os
import signal
import subprocess

@dataclass
class NativeResult:
    stdout: bytes
    returncode: int
    instrument_error: str | None = None

class _Interrupted(Exception):
    pass


def _retire_owned(process):
    # A live, unreaped Popen child cannot have its PID reused. Recheck the
    # captured private session/group before signaling that group.
    def send(sig):
        if process.returncode is not None:return
        try:
            private=(os.getpgid(process.pid)==process.pid and os.getsid(process.pid)==process.pid)
        except ProcessLookupError:
            return
        if private:os.killpg(process.pid,sig)
        elif sig==signal.SIGTERM:process.terminate()  # exact Popen child only
        else:process.kill()
    try:send(signal.SIGTERM)
    except ProcessLookupError:pass
    try:return process.communicate(timeout=2)[0],None
    except subprocess.TimeoutExpired:
        try:send(signal.SIGKILL)
        except ProcessLookupError:pass
        try:return process.communicate(timeout=5)[0],None
        except subprocess.TimeoutExpired as error:
            # A leader that exited but left pipe holders has no verifiable live
            # session leader. Never signal an unverified/reused group ID.
            if process.stdout:process.stdout.close()
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                return error.output or b'', 'owned native reap did not finish within cleanup bound'
            return error.output or b'', 'owned native reaped but unverified pipe holders remain'


def run_owned_native(argv,env,timeout):
    process=None;interrupted=None;retiring=False;output=b'';reason=None
    handled=[signal.SIGTERM,signal.SIGINT,signal.SIGHUP,signal.SIGALRM]
    previous={sig:signal.getsignal(sig) for sig in handled}
    def stop(signum,frame):
        nonlocal interrupted
        interrupted=signum
        # A signal during Popen construction is recorded, then handled once
        # the captured child handle is available. Do not lose that child.
        if process is not None and not retiring:raise _Interrupted()
    for sig in handled:signal.signal(sig,stop)
    try:
        try:
            process=subprocess.Popen(argv,env=env,stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,start_new_session=True)
            if interrupted is not None:raise _Interrupted()
            output=process.communicate(timeout=timeout)[0]
        except subprocess.TimeoutExpired:
            reason='owned native timeout; private child terminated and reaped'
            retiring=True;output,cleanup_error=_retire_owned(process)
            if cleanup_error:reason=cleanup_error
        except _Interrupted:
            reason='owned native interrupted by signal '+str(interrupted)+'; private child terminated and reaped'
            retiring=True;output,cleanup_error=_retire_owned(process)
            if cleanup_error:reason=cleanup_error
    finally:
        retiring=True
        for sig,handler in previous.items():signal.signal(sig,handler)
    if interrupted is not None and reason is None:
        reason='owned native interrupted by signal '+str(interrupted)
    return NativeResult(output,process.returncode,reason)


@contextmanager
def awake_hold():
    # Watch this exact Python PID. If Python dies, caffeinate releases its
    # assertion itself; normal completion also terminates/reaps this own child.
    process=subprocess.Popen(['/usr/bin/caffeinate','-d','-i','-w',str(os.getpid())],
        stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:yield
    finally:
        process.terminate()
        try:process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill();process.wait(timeout=2)
