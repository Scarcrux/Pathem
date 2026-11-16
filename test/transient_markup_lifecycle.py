"""Post-reap disk evidence for the isolated application's real Quit/close paths."""
import hashlib
import json
from pathlib import Path
import re


def evaluate(log, code, mode, scratch):
    errors=[];findings=set();proof={}
    directory=Path(scratch)/'markup-lifecycle'
    witness=directory/'witness.json';fixture=directory/'owned-unsaved.pdf'
    try:
        if witness.is_symlink() or fixture.is_symlink():raise ValueError('symlink fixture')
        proof=json.loads(witness.read_text())
        if proof['mode']!=mode or proof['fixture']!=fixture.name:raise ValueError('wrong mode/fixture')
        if proof['edited_before'] is not True or proof['save_control'] is not True:raise ValueError('treatment/control absent')
        if proof['delegate']!='PathemAppDelegate':raise ValueError('wrong application delegate')
        if not re.fullmatch('[0-9a-f]{64}',proof['before_sha256']):raise ValueError('invalid original digest')
        actual=hashlib.sha256(fixture.read_bytes()).hexdigest()
        if actual!=proof['after_sha256']:raise ValueError('post-reap bytes differ from native witness')
        if not isinstance(proof['disk_annotations'],int) or proof['disk_annotations']<0:raise ValueError('unreadable PDF')
        if mode=='quit':
            if proof['quit_requested'] is not True:raise ValueError('Quit not requested')
            if proof['will_terminate']:
                if code!=0 or proof['stage']!='will-terminate' or 'TLIFECYCLE: WILL-TERMINATE mode=quit' not in log or 'TLIFECYCLE: QUIT-REQUEST mode=quit' not in log:
                    raise ValueError('no natural real-app termination receipt')
            elif proof['stage']!='quit-refused' or not proof['prompt_seen']:
                raise ValueError('termination missing without a witnessed product guard')
        elif mode=='close':
            closed=proof['stage']=='closed' and proof['window_closed'] is True
            guarded=(proof['stage']=='close-refused' and proof['window_closed'] is False
                     and proof['prompt_seen'] is True and proof.get('edited_after') is True
                     and proof.get('close_requested') is True)
            if not (closed or guarded):
                raise ValueError('real owned window neither closed nor preserved by a witnessed guard')
        else:raise ValueError('unknown lifecycle mode')
        if proof['prompt_seen'] is not False and proof['prompt_seen'] is not True:
            raise ValueError('prompt observation missing')
        if proof['disk_annotations']==0 and actual!=proof['before_sha256']:
            raise ValueError('changed PDF without saved annotations needs review')
        lost=proof['prompt_seen'] is False and proof['disk_annotations']==0 and actual==proof['before_sha256']
        if lost:findings.add(('L-'+mode,5))
        proof['post_reap_sha256']=actual
        proof['lost_without_prompt']=lost
    except (KeyError,ValueError,OSError,TypeError) as error:
        errors.append('markup lifecycle evidence incomplete: '+str(error))
    return errors,findings,proof
