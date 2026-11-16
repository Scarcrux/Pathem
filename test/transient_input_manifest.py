"""Closed local runtime/build inputs for the private transient fixture binary."""
from pathlib import Path
import hashlib
import subprocess
from transient_app_bundle import dependency_paths


def paths(root):
    root = Path(root)
    selected = set()
    for name in ['Sources', 'vendor']:
        selected.update(p for p in (root/name).rglob('*') if p.is_file())
    selected.update(p for p in [root/'Package.swift', root/'Package.resolved'] if p.is_file())
    selected.update(p for p in (root/'test').glob('transient*.py') if p.is_file())
    isolation_helper=root/'test/layout_matrix_support.py'
    if isolation_helper.is_file(): selected.add(isolation_helper)
    selected.update(p for p in (root/'test').glob('transient*.json') if p.name != 'transient_known_findings.json')
    binary = root/'.build/debug/Pathem'
    selected.add(binary)
    selected.update(p for p in (binary.parent/'Pathem_Pathem.bundle').rglob('*') if p.is_file())
    dependencies = dependency_paths(subprocess.check_output(['otool','-L',str(binary)],text=True))
    for path in dependencies:
        if path.startswith(('/usr/lib/','/System/Library/')): continue
        if not path.startswith('@rpath/'): raise ValueError('Unclassified linked dependency input: '+path)
        relative = Path(path.removeprefix('@rpath/'))
        if relative.is_absolute() or '..' in relative.parts: raise ValueError('Unsafe linked dependency')
        if str(relative).startswith('libswift') and '.framework' not in str(relative): continue
        if not (binary.parent/relative).is_file(): raise ValueError('Missing linked dependency input: '+path)
        source = binary.parent/relative.parts[0]
        if source.is_dir(): selected.update(p for p in source.rglob('*') if p.is_file())
        elif source.is_file(): selected.add(source)
        else: raise ValueError('Missing linked dependency input: '+path)
    if not binary.is_file(): raise ValueError('Missing native binary input')
    return sorted(selected)


def digest(root):
    root = Path(root)
    digest = hashlib.sha256()
    for path in paths(root):
        digest.update(str(path.relative_to(root)).encode())
        with path.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024*1024),b''): digest.update(chunk)
    return digest.hexdigest()
