"""Exact known-findings comparison. Incomplete or unsafe receipts are never baselines."""
from collections import Counter
from transient_render_evidence import verify_failure_renders

PRODUCT_ERRORS=('clean native verdict red:', 'lifecycle product verdict red:')

def compare(observed, baseline):
    errors=[];expected=set()
    for row in baseline:
        try:
            pair=(row['cell'],row['check'])
            if not isinstance(pair[0],str) or not isinstance(pair[1],int) or not 1<=pair[1]<=8:
                raise ValueError('only product checks 1 through 8 can be listed')
            if pair[0].startswith(('predicate-','full-B-contract','mount-','factory-','lifecycle-setup')):
                raise ValueError('instrument/control failure cannot be listed')
            if pair in expected:raise ValueError('duplicate cell/check')
            if not all(isinstance(row.get(k),str) and row[k].strip() for k in ['id','mechanism','source','receipt','render']):
                raise ValueError('finding evidence missing')
            expected.add(pair)
        except (KeyError,TypeError,ValueError) as error:
            errors.append('invalid known finding: '+str(error))
    actual=set(observed)
    if actual-expected:errors.append('NEW failures: '+repr(sorted(actual-expected)))
    if expected-actual:errors.append('STALE known findings: '+repr(sorted(expected-actual)))
    return errors


def collect(receipts, expected_labels, digest):
    errors=[];failures=set()
    labels=[r.get('label') for r in receipts]
    if Counter(labels)!=Counter(expected_labels):errors.append('receipt plan incomplete or duplicated')
    for r in receipts:
        label=r.get('label','missing')
        if r.get('source_digest')!=digest:errors.append('source/artifact differs: '+label)
        if not all(r.get(k) is True for k in ['preferences_unchanged','demo_removed','private_domain_removed','catalog_matches_source']):
            errors.append('launch isolation or localization failed: '+label)
        if r.get('native_exit') not in (0,1):errors.append('non-terminal or abnormal native exit: '+label)
        if any(not any(e.startswith(prefix) for prefix in PRODUCT_ERRORS) for e in r.get('errors',[])):
            errors.append('instrument errors cannot be baselined: '+label)
        raw_pairs=r.get('failures',[])
        if not isinstance(raw_pairs,list) or any(not isinstance(pair,(list,tuple)) or len(pair)!=2 or not isinstance(pair[0],str) or type(pair[1]) is not int for pair in raw_pairs):
            errors.append('malformed failure evidence: '+label)
            continue
        pairs={tuple(pair) for pair in raw_pairs}
        if any(not isinstance(check,int) or not 1<=check<=8 or cell.startswith(('predicate-','full-B-contract','mount-','factory-','lifecycle-setup')) for cell,check in pairs):
            errors.append('setup/control failure cannot be baselined: '+label)
        proof=r.get('lifecycle_disk_proof') or {}
        parent_quit=(r.get('category')=='lifecycle' and proof.get('mode')=='quit'
                     and proof.get('will_terminate') is True and proof.get('quit_requested') is True
                     and proof.get('edited_before') is True and proof.get('save_control') is True
                     and proof.get('lost_without_prompt') is True and proof.get('disk_annotations')==0
                     and proof.get('prompt_seen') is False
                     and proof.get('post_reap_sha256')==proof.get('before_sha256')
                     and isinstance(proof.get('before_sha256'),str))
        if r.get('native_exit')==0 and pairs and not parent_quit:
            errors.append('native zero contradicts failure assertions: '+label)
        if r.get('native_exit')==1 and not pairs:errors.append('native red has no named failure: '+label)
        errors += verify_failure_renders(r)
        failures |= pairs
    return errors,failures
