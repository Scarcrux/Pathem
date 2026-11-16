"""Current-run failure screenshots, decoded structurally and bound to launch receipts."""
from collections import Counter
import hashlib
from pathlib import Path
import re
import shutil
import struct
import zlib

SIGNATURE=b'\x89PNG\r\n\x1a\n'
MAX_DECODED=128*1024*1024


def png_evidence(path):
    path=Path(path)
    if path.is_symlink() or not path.is_file():raise ValueError('missing or symlink render')
    data=path.read_bytes()
    if not data.startswith(SIGNATURE):raise ValueError('render is not PNG')
    offset=8;header=None;compressed=bytearray();ended=False;palette=False
    while offset<len(data):
        if offset+12>len(data):raise ValueError('truncated PNG chunk')
        length=struct.unpack('>I',data[offset:offset+4])[0]
        kind=data[offset+4:offset+8];end=offset+8+length
        if end+4>len(data):raise ValueError('truncated PNG payload')
        payload=data[offset+8:end]
        if zlib.crc32(kind+payload)&0xffffffff!=struct.unpack('>I',data[end:end+4])[0]:raise ValueError('PNG checksum mismatch')
        if header is None and kind!=b'IHDR':raise ValueError('PNG header must be first')
        if kind==b'IHDR':
            if header is not None or len(payload)!=13:raise ValueError('invalid PNG header')
            header=struct.unpack('>IIBBBBB',payload)
        elif kind==b'PLTE':
            if not payload or len(payload)%3 or len(payload)>768:raise ValueError('invalid PNG palette')
            palette=True
        elif kind==b'IDAT':compressed.extend(payload)
        elif kind==b'IEND':
            if payload:raise ValueError('invalid PNG end')
            ended=True;offset=end+4;break
        elif kind[0]&32==0:raise ValueError('unsupported PNG critical chunk')
        offset=end+4
    if header is None or not ended or offset!=len(data) or not compressed:raise ValueError('incomplete PNG')
    width,height,depth,color,compression,filtering,interlace=header
    allowed={0:{1,2,4,8,16},2:{8,16},3:{1,2,4,8},4:{8,16},6:{8,16}}
    if not width or not height or color not in allowed or depth not in allowed[color] or compression or filtering or interlace not in (0,1):raise ValueError('invalid PNG format')
    if color==3 and not palette:raise ValueError('indexed PNG lacks palette')
    channels={0:1,2:3,3:1,4:2,6:4}[color]
    passes=[(0,0,1,1)] if not interlace else [(0,0,8,8),(4,0,8,8),(0,4,4,8),(2,0,4,4),(0,2,2,4),(1,0,2,2),(0,1,1,2)]
    scanlines=[];expected=0
    for x,y,dx,dy in passes:
        w=max(0,(width-x+dx-1)//dx);h=max(0,(height-y+dy-1)//dy)
        if not w or not h:continue
        stride=1+(w*channels*depth+7)//8
        expected+=stride*h;scanlines.append((h,stride))
    if expected>MAX_DECODED:raise ValueError('PNG decode exceeds bounded render budget')
    decoder=zlib.decompressobj()
    try:decoded=decoder.decompress(bytes(compressed),expected+1)
    except zlib.error as error:raise ValueError('unreadable PNG data') from error
    if not decoder.eof or decoder.unconsumed_tail or decoder.unused_data or len(decoded)!=expected:raise ValueError('PNG decoded size/stream mismatch')
    index=0
    for rows,stride in scanlines:
        for _ in range(rows):
            if decoded[index]>4:raise ValueError('invalid PNG scanline filter')
            index+=stride
    return dict(sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),width=width,height=height)


def gather_failure_renders(scratch,failures,category,proof,artifact_root,launch_id,source_digest):
    """Copy only current launch captures, never manufacture or use baseline imagery."""
    scratch=Path(scratch);artifact_root=Path(artifact_root)
    if not re.fullmatch('[0-9a-f]{32}',launch_id):return ['failure render evidence: invalid launch identity'],[]
    pending=[];errors=[]
    for cell,check in sorted(failures):
        if not 1<=check<=8 or cell.startswith(('predicate-','full-B-contract','mount-','factory-','core-contract','lifecycle-setup')):continue
        if not re.fullmatch('[A-Za-z0-9_-]+',cell):
            errors.append('failure render evidence: unsafe cell name');continue
        source=scratch/f'{cell}-check{check}.png';stage='failure'
        if cell.startswith('L-'):
            mode=cell.removeprefix('L-')
            if category!='lifecycle' or (proof or {}).get('mode')!=mode or (proof or {}).get('edited_before') is not True:
                errors.append('failure render evidence: lifecycle treatment missing: '+cell);continue
            stage='prompt' if (proof or {}).get('prompt_seen') else 'before'
            source=scratch/f'{cell}-{stage}.png'
        try:metadata=png_evidence(source)
        except (ValueError,OSError) as error:
            errors.append(f'failure render evidence: {cell} check{check}: {error}');continue
        pending.append((cell,check,source,stage,metadata))
    if errors:return errors,[]
    if pending:
        artifact_root.mkdir(parents=True,exist_ok=False)
    evidence=[]
    for cell,check,source,stage,metadata in pending:
        target=artifact_root/f'{cell}-check{check}.png'
        shutil.copy2(source,target)
        if png_evidence(target)!=metadata:raise ValueError('failure render evidence changed during retention')
        evidence.append(dict(cell=cell,check=check,path=str(target),capture_stage=stage,
            launch_id=launch_id,source_digest=source_digest,**metadata))
    return [],evidence


def verify_failure_renders(receipt,native_log=None):
    errors=[];rows=receipt.get('failure_renders')
    if native_log is not None and receipt.get('native_log_sha256')!=hashlib.sha256(native_log.encode() if isinstance(native_log,str) else native_log).hexdigest():
        errors.append('failure render evidence: native receipt hash differs')
    if not isinstance(rows,list):return ['failure render evidence: manifest missing']
    try:
        pairs=[tuple(pair) for pair in receipt.get('failures',[]) if 1<=pair[1]<=8
            and not pair[0].startswith(('predicate-','full-B-contract','mount-','factory-','core-contract','lifecycle-setup'))]
        if Counter((r['cell'],r['check']) for r in rows)!=Counter(pairs):raise ValueError('manifest pairs differ from failed checks')
        for row in rows:
            if row['cell'].startswith('L-'):
                proof=receipt.get('lifecycle_disk_proof') or {}
                stage='prompt' if proof.get('prompt_seen') else 'before'
                if receipt.get('category')!='lifecycle' or proof.get('mode')!=row['cell'][2:] or proof.get('edited_before') is not True or row.get('capture_stage')!=stage:raise ValueError('lifecycle image stage/treatment differs')
            elif row.get('capture_stage')!='failure':raise ValueError('product failure image stage differs')
            if row['launch_id']!=receipt['launch_id'] or row['source_digest']!=receipt['source_digest']:raise ValueError('manifest belongs to another launch/source')
            path=Path(row['path'])
            if path.parent.name!=receipt['launch_id'] or path.name!=f"{row['cell']}-check{row['check']}.png":raise ValueError('manifest render path is not launch scoped')
            if png_evidence(path)!={k:row[k] for k in ['sha256','bytes','width','height']}:raise ValueError('retained render fingerprint changed')
    except (KeyError,ValueError,OSError,TypeError) as error:errors.append('failure render evidence: '+str(error))
    return errors
