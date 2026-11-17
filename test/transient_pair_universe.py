"""Product cell/check pairs that the actual selected transient plan can emit."""
from pathlib import Path
from transient_mounts import validate as validate_mounts
from transient_factories import validate as validate_factories
from transient_full_alerts import validate as validate_alerts
from transient_core_receipts import cells as core_cells
from transient_catalogs import shipped_languages, A_LANGUAGES
ROOT=Path(__file__).resolve().parents[1]


def planned_pairs(jobs=None,root=ROOT):
    if jobs is None:
        from transient_full_plan import plan
        jobs=plan(root)
    result=set();cache={}
    for job in jobs:
        category=job['category'];language=job['language'];group=job.get('group',0);only=job.get('only')
        if language not in shipped_languages(root):raise ValueError('unknown planned language: '+str(language))
        if category in {'core','mounts','factories'} and language not in A_LANGUAGES:
            raise ValueError('class A plan requires de or ja')
        if category=='core':
            cells=core_cells(language)
            if not cells:raise ValueError('core plan requires de or ja')
            result.update((cell,n) for cell in cells for n in range(1,9))
        elif category in ('mounts','factories','b'):
            if category not in cache:
                cache[category]={'mounts':validate_mounts,'factories':validate_factories,'b':validate_alerts}[category](root)
            recipes=[r for r in cache[category] if (not group or r.get('group')==group) and (only is None or r['id']==only)]
            if not recipes:raise ValueError('empty or unknown planned surface set: '+category)
            for row in recipes:
                if category=='b':
                    for size in [720,1100]:
                        cell=f'B-{row["id"]}-{language}-{size}'
                        result.update((cell,n) for n in [1,2,3])
                        if language=='de' and row['sheet']:
                            result.update((cell+'-lifecycle',n) for n in range(1,9))
                else:
                    prefix='M' if category=='mounts' else 'F'
                    for appearance in ['light','dark']:
                        for size in [720,1100]:
                            for name in (['short','long255'] if row['filename'] else ['short']):
                                cell=f'{prefix}-{row["id"]}-{language}-{appearance}-{size}-{name}'
                                result.update((cell,n) for n in range(1,9))
        elif category=='lifecycle':
            if only not in ['close','quit']:raise ValueError('unknown planned lifecycle mode')
            result.update(('L-'+only,n) for n in ([4,5] if only=='close' else [5]))
        else:raise ValueError('unknown transient plan category: '+str(category))
    return result


def validate_jobs(jobs,root=ROOT):
    """Reject an empty, duplicate or noncanonical invocation plan before side effects."""
    if not isinstance(jobs,list) or not jobs:
        raise ValueError('selected plan must be a nonempty job list')
    labels=set()
    fields={'category','language','group','only','label'}
    for job in jobs:
        if not isinstance(job,dict) or set(job)!=fields:
            raise ValueError('selected plan job has unknown or missing fields')
        category=job['category'];language=job['language'];group=job['group'];only=job['only']
        if not isinstance(category,str) or not isinstance(language,str) or category not in {'core','mounts','factories','b','lifecycle'} or language not in shipped_languages(root):
            raise ValueError('selected plan has unknown category or language')
        if type(group) is not int or group<0 or (only is not None and (not isinstance(only,str) or not only)):
            raise ValueError('selected plan has invalid group or surface selector')
        if category in {'core','mounts','factories'} and language not in A_LANGUAGES:
            raise ValueError('class A selected plan requires de or ja')
        if category=='core' and (group!=0 or only is not None):
            raise ValueError('core selected plan must use its complete contracted treatment')
        if category=='b' and group!=0:
            raise ValueError('plain-alert selected plan has no group selector')
        if category=='lifecycle' and (language!='de' or group!=0 or only not in {'close','quit'}):
            raise ValueError('lifecycle selected plan differs from contracted modes')
        expected=f'clean-{language}-full-{category}-g{group}'+('-'+only if only is not None else '')
        if job['label']!=expected:
            raise ValueError('selected plan label is not canonical for its invocation')
        if expected in labels:
            raise ValueError('selected plan contains duplicate jobs')
        labels.add(expected)
