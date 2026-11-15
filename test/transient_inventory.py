#!/usr/bin/env python3
"""Lexical source census. Classification is reviewed data, never a green default."""
import argparse
import collections
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'test/transient_inventory.json'
TABLE = ROOT / 'docs/TRANSIENT_INVENTORY.md'
BUILD_TYPES = ['NSAlert', 'NSOpenPanel', 'NSSavePanel', 'NSMenu', 'NSPopover', 'NSWindow', 'NSPanel', 'NSSharingServicePicker']
BUILD = re.compile(r'\b(' + '|'.join(BUILD_TYPES) + r')\s*\(')
PRESENT = re.compile(
    r'(?P<receiver>[\w.?!]+)\s*\.\s*(?P<method>beginSheetModal|beginSheet|runModal|showWindow|makeKeyAndOrderFront|orderFront|popUpContextMenu|popUp)\s*\('
    r'|(?P<popreceiver>[\w.?!]+)\s*\.\s*(?P<popmethod>show)\s*\(\s*relativeTo\s*:')
STRING_OPEN = re.compile(r'(\#*)("""|")')


def mask(source):
    """Keep offsets/newlines; exclude comments and string contents from the census.

    Interpolated expressions are restored as code, including nested strings/comments.
    """
    result = list(source)

    def blank(start, end):
        for n in range(start, end):
            if source[n] != '\n':
                result[n] = ' '

    def code(i, interpolation=False):
        depth = 1
        while i < len(source):
            if source.startswith('//', i):
                end = source.find('\n', i)
                end = len(source) if end < 0 else end
                blank(i, end)
                i = end
            elif source.startswith('/*', i):
                start, level = i, 1
                i += 2
                while i < len(source) and level:
                    if source.startswith('/*', i):
                        level += 1
                        i += 2
                    elif source.startswith('*/', i):
                        level -= 1
                        i += 2
                    else:
                        i += 1
                blank(start, i)
            elif STRING_OPEN.match(source, i):
                opening = STRING_OPEN.match(source, i)
                hashes, quotes = opening.groups()
                start = i
                i += len(opening[0])
                blank(start, i)
                terminator, escape = quotes + hashes, '\\' + hashes
                while i < len(source):
                    if source.startswith(terminator, i):
                        blank(i, i + len(terminator))
                        i += len(terminator)
                        break
                    if source.startswith(escape + '(', i):
                        blank(i, i + len(escape) + 1)
                        i = code(i + len(escape) + 1, True)
                    elif source.startswith(escape, i):
                        end = min(len(source), i + len(escape) + 1)
                        blank(i, end)
                        i = end
                    else:
                        blank(i, i + 1)
                        i += 1
            elif interpolation and source[i] == '(':
                depth += 1
                i += 1
            elif interpolation and source[i] == ')':
                depth -= 1
                if depth == 0:
                    blank(i, i + 1)
                    return i + 1
                i += 1
            else:
                i += 1
        return i

    code(0)
    return ''.join(result)


def debug_lines(source):
    """Exclude explicit DEBUG branches; retain their release else branches."""
    stack, excluded = [], set()
    for number, line in enumerate(mask(source).splitlines(), 1):
        directive = re.match(r'\s*#(if|elseif|else|endif)\b(.*)', line)
        if directive:
            kind, expression = directive.groups()
            if kind == 'if':
                stack.append(
                    '!DEBUG' not in expression.replace(' ', '')
                    if re.search(r'\bDEBUG\b', expression) else None)
            elif kind in ('else', 'elseif') and stack:
                if kind == 'else':
                    stack[-1] = not stack[-1] if stack[-1] is not None else None
                else:
                    stack[-1] = ('!DEBUG' not in expression.replace(' ', '')
                                 if re.search(r'\bDEBUG\b', expression) else None)
            elif kind == 'endif' and stack:
                stack.pop()
        elif any(item is True for item in stack):
            excluded.add(number)
    return excluded


def scan(root, exclusions):
    builders, sites, ignored = {}, {}, collections.Counter()
    paths = sorted((root / 'Sources/Pathem').rglob('*.swift'))
    masked = {path: mask(path.read_text()) for path in paths}
    # Include app-owned NSWindow/NSPanel subclasses, not just base constructors.
    types = set(BUILD_TYPES)
    while True:
        found = {m[1] for code in masked.values() for m in re.finditer(
            r'\bclass\s+(\w+)\s*:\s*(' + '|'.join(sorted(types)) + r')\b', code)}
        if found <= types:
            break
        types.update(found)
    build_pattern = re.compile(r'\b(' + '|'.join(sorted(types)) + r')\s*\(')
    for path in paths:
        relative = path.relative_to(root).as_posix()
        source = path.read_text()
        code = masked[path]
        debug = debug_lines(source)
        for role, pattern in [('build', build_pattern), ('present', PRESENT)]:
            for match in pattern.finditer(code):
                line = source.count('\n', 0, match.start()) + 1
                column = match.start() - source.rfind('\n', 0, match.start())
                if relative in exclusions or line in debug:
                    ignored[relative] += 1
                    continue
                method = match[1] if role == 'build' else match['method'] or match['popmethod']
                key = f'{relative}:{line}:{column}:{method}'
                record = dict(file=relative, line=line, column=column, method=method)
                if role == 'present':
                    record['receiver'] = match['receiver'] or match['popreceiver']
                (builders if role == 'build' else sites)[key] = record
    return builders, sites, dict(sorted(ignored.items()))


def validate(builders, sites, manifest):
    errors = []
    for key in sorted(sites.keys() - manifest['sites'].keys()):
        errors.append('UNCLASSIFIED presentation ' + key)
    for key in sorted(manifest['sites'].keys() - sites.keys()):
        errors.append('STALE presentation ' + key)
    for key in sorted(sites.keys() & manifest['sites'].keys()):
        item = manifest['sites'][key]
        if item.get('class') not in ['A', 'B', 'C'] or not item.get('reason'):
            errors.append('UNCLASSIFIED metadata ' + key)
        if not item.get('builders'):
            errors.append('UNLINKED builder ' + key)
        for builder in item.get('builders', []):
            if builder not in builders:
                errors.append('STALE builder link ' + key + ' -> ' + builder)
        for field in ['kind', 'custom_content', 'destructive', 'default_destructive_intended']:
            if field not in item:
                errors.append('MISSING ' + field + ' ' + key)
    linked = {b for item in manifest['sites'].values() for b in item.get('builders', [])}
    for key in sorted(builders.keys() - linked):
        if not manifest.get('unpresented_builders', {}).get(key):
            errors.append('UNPRESENTED builder requires reason ' + key)
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scan', action='store_true', help='Read-only discovery, not classification')
    args = parser.parse_args()
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {'exclude_files': {}, 'sites': {}}
    builders, sites, ignored = scan(ROOT, manifest.get('exclude_files', {}))
    if args.scan:
        print(json.dumps(dict(builders=builders, sites=sites, ignored=ignored), indent=2))
        return
    errors = validate(builders, sites, manifest)
    for error in errors:
        print(error)
    print(f'INVENTORY: builders={len(builders)} presentations={len(sites)} excluded={sum(ignored.values())}')
    print('RESULT: ' + ('FAIL' if errors else 'PASS'))
    raise SystemExit(bool(errors))


if __name__ == '__main__':
    main()
