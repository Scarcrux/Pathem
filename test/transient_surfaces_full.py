#!/usr/bin/env python3
"""Run every contracted transient variant and compare exact known findings."""
import argparse
import hashlib
from contextlib import redirect_stdout, redirect_stderr, nullcontext
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import sys
import time
import uuid
from transient_full_plan import coverage, plan, focused_plan, ROOT
from transient_known_findings import collect, compare
from transient_render_evidence import verify_failure_renders
from transient_pair_universe import planned_pairs, validate_jobs
from transient_surfaces_sample import run_case, source_digest
from transient_process import awake_hold
from transient_deadline import bounded_native_timeout, RUN_BUDGET_SECONDS, CLEANUP_MARGIN_SECONDS


def load_known_findings(path,jobs=None):
    # Fail before AppKit or output creation. Freeze the reviewed baseline bytes
    # for the whole run instead of rereading a moving file after native work.
    raw=Path(path).read_bytes()
    document=json.loads(raw)
    if not isinstance(document,dict) or not isinstance(document.get('findings'),list):
        raise ValueError('known-findings baseline must contain a findings list')
    rows=document['findings']
    if any(not isinstance(row,dict) or not isinstance(row.get('cell'),str)
           or type(row.get('check')) is not int for row in rows):
        raise ValueError('known-findings baseline has malformed cell/check evidence')
    errors=compare({(row['cell'],row['check']) for row in rows},rows)
    if errors:raise ValueError('invalid known-findings baseline: '+repr(errors))
    if rows:
        unknown={(row['cell'],row['check']) for row in rows}-planned_pairs(jobs)
        if unknown:raise ValueError('known findings outside selected plan: '+repr(sorted(unknown)))
    return rows,hashlib.sha256(raw).hexdigest()


def run(output, baseline=None, jobs=None, awake=False):
    started = time.monotonic()
    deadline = started + RUN_BUDGET_SECONDS
    jobs = jobs if jobs is not None else plan()
    validate_jobs(jobs)
    planned_pairs(jobs)  # Validate selections even when the reviewed baseline is empty.
    baseline_rows,baseline_sha256=load_known_findings(baseline,jobs) if baseline is not None else (None,None)
    output.mkdir(parents=True, exist_ok=False)
    counts = coverage()
    digest = source_digest()
    errors = []
    receipts = []
    (output/'plan.json').write_text(json.dumps(dict(source_digest=digest, baseline_sha256=baseline_sha256, budget_seconds=RUN_BUDGET_SECONDS, cleanup_margin_seconds=CLEANUP_MARGIN_SECONDS, coverage=counts, jobs=jobs),indent=2)+'\n')
    with awake_hold() if awake else nullcontext():
        for job in jobs:
            label = job['label']
            native_timeout = bounded_native_timeout(deadline=deadline)
            if native_timeout is None:
                errors.append('whole-run budget exhausted before job admission: '+label)
                break
            print('TRANSIENT FULL: start '+label,flush=True)
            launch_id = uuid.uuid4().hex
            with (output/(label+'.driver.log')).open('w') as log, redirect_stdout(log), redirect_stderr(log):
                run_case('clean',job['language'],False,True,job['category'],job['group'],False,job['only'],launch_id=launch_id,native_timeout=native_timeout,deadline=deadline)
            receipt = ROOT/'.build'/('transient-sample-'+label+'.json')
            if not receipt.is_file():
                errors.append('missing receipt: '+label)
                break
            data = json.loads(receipt.read_text())
            if data.get('launch_id') != launch_id:
                errors.append('stale receipt: fresh launch identity missing: '+label)
                break
            receipts.append(data)
            shutil.copy2(receipt,output/(label+'.json'))
            shutil.copy2(receipt.with_suffix('.log'),output/(label+'.native.log'))
            refused = verify_failure_renders(data, receipt.with_suffix('.log').read_bytes()) + [e for e in data['errors'] if not e.startswith(('clean native verdict red:', 'lifecycle product verdict red:'))]
            print(f'TRANSIENT FULL: native={data["native_exit"]} pairs={len(data["failures"])} seconds={data["seconds"]:.2f} '+label,flush=True)
            if refused:
                errors += [label+': '+e for e in refused]
                break  # No further expansion after an instrument or isolation failure.
    collection_errors, failures = collect(receipts,[j['label'] for j in jobs],digest)
    errors += collection_errors
    if source_digest() != digest: errors.append('inputs changed across the complete run')
    if time.monotonic() > deadline: errors.append('whole-run budget exceeded during cleanup or receipt finalization')
    if baseline is not None:
        errors += compare(failures,baseline_rows)
    else:
        errors.append('recording only: no known-findings acceptance requested')
    result = dict(source_digest=digest, baseline_sha256=baseline_sha256, budget_seconds=RUN_BUDGET_SECONDS, cleanup_margin_seconds=CLEANUP_MARGIN_SECONDS, coverage=counts, receipts=[r['label'] for r in receipts],
        failures=sorted(failures), errors=errors, seconds=time.monotonic()-started)
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    print('TRANSIENT FULL: planned inventory coverage '+json.dumps(counts),flush=True)
    print(f'TRANSIENT FULL: {len(receipts)}/{len(jobs)} launches; {len(failures)} native failure pairs; {result["seconds"]:.2f} seconds',flush=True)
    for error in errors: print('TRANSIENT FULL: '+error,flush=True)
    if not errors: print('TRANSIENT FULL: BASELINE MATCH (raw native verdicts retained)',flush=True)
    print('RESULT: '+('FAIL' if errors else 'PASS')+' transient known-findings comparison',flush=True)
    return not errors


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    mode=parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--plan',action='store_true',help='Print the invocation plan only; never launch the app')
    mode.add_argument('--record',action='store_true')
    mode.add_argument('--known-findings',type=Path)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--surface',action='append',default=[],help='Development subset ID, e.g. m39; repeatable, cannot qualify a full baseline')
    args=parser.parse_args()
    if args.surface and args.known_findings:
        parser.error('focused runs cannot qualify the full known-findings baseline')
    try:
        jobs = focused_plan(args.surface) if args.surface else plan()
    except ValueError as error:
        parser.error(str(error))
    if args.plan:
        print(json.dumps(dict(mode='plan-only', gui_launches=0, planned_inventory=coverage(),
            scope='focused-development' if args.surface else 'full', jobs=jobs),indent=2))
        print('RESULT: PASS plan only; no application launched')
        return
    os.umask(0o077)
    stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    output=args.output or ROOT/'.build'/('transient-full-'+stamp)
    try: ok=run(output,args.known_findings,jobs,awake=True)
    except Exception as error:
        print('TRANSIENT FULL: refused '+str(error),flush=True)
        print('RESULT: FAIL transient full runner',flush=True)
        raise SystemExit(2)
    raise SystemExit(not ok)


if __name__=='__main__':main()
