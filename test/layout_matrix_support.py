"""Read-only defaults comparison. Matching owner state is never written to disk."""
import os
import pathlib
import plistlib
import subprocess


def defaults_snapshot():
    result = {}
    for domain in ['Pathem', 'com.scarcrux.pathem']:
        run = subprocess.run(['/usr/bin/defaults', 'export', domain, '-'], capture_output=True)
        result[domain] = plistlib.loads(run.stdout) if run.returncode == 0 else {}
    return result


def verify_defaults(before, directory):
    after = defaults_snapshot()
    if before == after:
        return True
    for name, values in [('before', before), ('after', after)]:
        path = pathlib.Path(directory) / ('defaults-' + name + '.plist')
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            plistlib.dump(values, stream)
    return False
