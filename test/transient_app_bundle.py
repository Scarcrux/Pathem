"""Private AppKit preference domain with dependency-checked native packaging."""
from pathlib import Path, PurePosixPath
import plistlib
import shutil


def dependency_paths(otool_output):
    return [line.strip().split(' (compatibility', 1)[0] for line in otool_output.splitlines()[1:] if line.strip()]


def prepare_bundle(scratch, source, domain, dependencies):
    if not domain.startswith('io.pathem.transient.fixture.'):
        raise ValueError('Only a private transient fixture domain is allowed')
    app = scratch/'TransientFixture.app'
    contents = app/'Contents'
    destination = contents/'MacOS'
    destination.mkdir(parents=True)
    executable = destination/'PathemTransientFixture'
    shutil.copy2(source, executable)
    for path in dependencies:
        if path.startswith(('/usr/lib/', '/System/Library/')):
            continue
        if not path.startswith('@rpath/'):
            raise ValueError('Unclassified native dependency: '+path)
        relative = PurePosixPath(path.removeprefix('@rpath/'))
        if '..' in relative.parts or relative.is_absolute():
            raise ValueError('Unsafe native dependency path')
        # Swift's system runtime is supplied by the OS dyld cache.
        if str(relative).startswith('libswift') and '.framework' not in str(relative):
            continue
        name = relative.parts[0]
        original = source.parent/name
        target = destination/name
        if not (source.parent/str(relative)).is_file():
            raise ValueError('Missing native dependency before launch: '+path)
        if not target.exists():
            if original.is_dir(): shutil.copytree(original,target,symlinks=True)
            else: shutil.copy2(original,target)
        if not (destination/str(relative)).is_file():
            raise ValueError('Packaged native dependency missing before launch: '+path)
    resources = source.parent/'Pathem_Pathem.bundle'
    if not resources.is_dir():
        raise ValueError('Missing native resource bundle before launch')
    resource_directory = contents/'Resources'
    resource_directory.mkdir()
    shutil.copytree(resources, resource_directory/'Pathem_Pathem.bundle', symlinks=True)
    with (contents/'Info.plist').open('wb') as stream:
        plistlib.dump(dict(CFBundleIdentifier=domain, CFBundleExecutable='PathemTransientFixture',
            CFBundleName='TransientFixture', CFBundlePackageType='APPL',
            NSHighResolutionCapable=True, CFBundleDevelopmentRegion='en',
            CFBundleLocalizations=['en','de','ja','fr','es','zh-Hans']),stream)
    return executable


def clear_private_domain(domain, run=None):
    """Delete only our exact UUID domain and require empty structured exports.

    On this macOS defaults read succeeds with {} for an absent domain, so its
    process exit alone cannot establish whether any preference keys survived.
    """
    import re
    import subprocess
    if not re.fullmatch(r'io\.pathem\.transient\.fixture\.[0-9a-f]{32}',domain):
        raise ValueError('Cleanup requires an exact owned UUID domain')
    run = run or subprocess.run
    for flags in [[], ['-currentHost']]:
        run(['defaults',*flags,'delete',domain],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        result=run(['defaults',*flags,'export',domain,'-'],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            if result.returncode != 0 or plistlib.loads(result.stdout) != {}:
                return False
        except (ValueError,plistlib.InvalidFileException):
            return False
    return True
