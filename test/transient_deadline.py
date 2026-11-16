"""Monotonic admission/native-wait budget, with time reserved for owned cleanup.

This is not an external watchdog or proof that arbitrary filesystem operations
finish by a hard deadline. subprocess.run retains responsibility for its own
child timeout/kill/reap when an admitted native wait expires.
"""
import math
import time
RUN_BUDGET_SECONDS = 2250.0
CLEANUP_MARGIN_SECONDS = 60.0
MAX_NATIVE_SECONDS = 180.0
MIN_NATIVE_SECONDS = 1.0


def validate_native_timeout(value):
    if isinstance(value,bool) or not isinstance(value,(int,float)) or not math.isfinite(value) or not 0 < value <= MAX_NATIVE_SECONDS:
        raise ValueError('native_timeout must be finite, positive and at most 180 seconds')
    return float(value)


def bounded_native_timeout(native_timeout=MAX_NATIVE_SECONDS, deadline=None,
                           cleanup_margin=CLEANUP_MARGIN_SECONDS, now=None):
    cap=validate_native_timeout(native_timeout)
    if deadline is None:return cap
    if isinstance(deadline,bool) or not isinstance(deadline,(int,float)) or not math.isfinite(deadline):
        raise ValueError('whole-run deadline must be a finite monotonic instant')
    if isinstance(cleanup_margin,bool) or not isinstance(cleanup_margin,(int,float)) or not math.isfinite(cleanup_margin) or cleanup_margin < 0:
        raise ValueError('cleanup margin must be finite and nonnegative')
    instant=time.monotonic() if now is None else now
    usable=deadline-instant-cleanup_margin
    return None if usable < MIN_NATIVE_SECONDS else min(cap,usable)
