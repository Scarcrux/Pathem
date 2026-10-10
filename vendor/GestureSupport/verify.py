#!/usr/bin/env python3
"""Check pinned package bytes without contacting a sibling checkout or network."""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def check(root):
    manifest = json.loads((root / 'manifest.json').read_text())
    if manifest.get('version') != '0.1.0' or not isinstance(manifest.get('files'), dict):
        raise ValueError('invalid package pin')
    actual = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in root.rglob('*') if p.is_file()
              and not any(part in ('.build', '.swiftpm', '.git', '__pycache__') for part in p.relative_to(root).parts)
              and p.name != 'manifest.json'}
    if actual != manifest['files']:
        raise ValueError('package bytes differ from pinned manifest')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compare', type=Path)
    args = parser.parse_args()
    try:
        pin = check(ROOT)
        if args.compare and check(args.compare) != pin:
            raise ValueError('package copies have different pins')
    except (ValueError, OSError, TypeError) as error:
        parser.exit(1, f'GestureSupport verification refused: {error}\n')
    print('GestureSupport 0.1.0 pinned bytes verified')


if __name__ == '__main__':
    main()
