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


def first_argument(code, start):
    level = 0
    for end in range(start, len(code)):
        character = code[end]
        if character in '([{':
            level += 1
        elif character in ')]}':
            if level == 0:
                return code[start:end].strip()
            level -= 1
        elif character == ',' and level == 0:
            return code[start:end].strip()
    raise ValueError('Unterminated wrapper invocation')


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


def release_condition(expression):
    """Three-valued condition: only DEBUG is known; unknown platform tests stay in."""
    expression = expression.strip()
    if expression.startswith('(') and expression.endswith(')'):
        depth = 0
        outer = True
        for n, char in enumerate(expression):
            depth += (char == '(') - (char == ')')
            if depth == 0 and n < len(expression) - 1:
                outer = False
                break
        if outer:
            return release_condition(expression[1:-1])
    for operator in ('||', '&&'):
        depth = 0
        for n, char in enumerate(expression):
            depth += (char == '(') - (char == ')')
            if depth == 0 and expression.startswith(operator, n):
                left = release_condition(expression[:n])
                right = release_condition(expression[n + 2:])
                if operator == '||':
                    return True if True in (left, right) else False if left is False and right is False else None
                return False if False in (left, right) else True if left is True and right is True else None
    if expression.startswith('!'):
        value = release_condition(expression[1:])
        return not value if value is not None else None
    return False if expression == 'DEBUG' else None


def debug_lines(source):
    """Exclude only branches proven unavailable when DEBUG is false.

    Unknown platform/compiler conditions retain every potentially reachable branch.
    Each frame holds the current branch and whether any earlier branch was taken.
    """
    stack, excluded = [], set()
    for number, line in enumerate(mask(source).splitlines(), 1):
        directive = re.match(r'\s*#(if|elseif|else|endif)\b(.*)', line)
        if directive:
            kind, expression = directive.groups()
            if kind == 'if':
                value = release_condition(expression)
                stack.append([value, value])
            elif kind in ('else', 'elseif') and stack:
                previous = stack[-1][1]
                condition = True if kind == 'else' else release_condition(expression)
                active = (False if previous is True or condition is False else
                          condition if previous is False else None)
                taken = (True if previous is True or condition is True else
                         False if previous is False and condition is False else None)
                stack[-1] = [active, taken]
            elif kind == 'endif' and stack:
                stack.pop()
        elif any(frame[0] is False for frame in stack):
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
    functions = []
    for path in paths:
        code = masked[path]
        relative = path.relative_to(root).as_posix()
        excluded = debug_lines(path.read_text())
        for match in re.finditer(r'\bfunc\s+(\w+)\s*\(([^{}]*?)\)[^{]*\{', code):
            line = code.count('\n', 0, match.start()) + 1
            if relative in exclusions or line in excluded:
                continue
            level, end = 1, match.end()
            while end < len(code) and level:
                level += (code[end] == '{') - (code[end] == '}')
                end += 1
            parameters = re.findall(r'(\w+)\s*:\s*NSAlert\b', match[2])
            functions.append(dict(file=relative, name=match[1], start=match.start(),
                                  body=match.end(), end=end, parameters=parameters))
    wrappers = {}
    # A pass-through presenter accepts an alert instead of building its content.
    # Iterate so a wrapper forwarding to another wrapper is resolved transitively.
    while True:
        before = len(wrappers)
        for function in functions:
            code = masked[root / function['file']][function['body']:function['end']]
            for parameter in function['parameters']:
                physical = any(m['receiver'] == parameter for m in PRESENT.finditer(code))
                forwarding = any(re.search(r'\b' + re.escape(name) + r'\s*\(\s*' + re.escape(parameter) + r'\s*[,)]', code) for name in wrappers)
                if physical or forwarding:
                    wrappers[function['name']] = dict(function, parameter=parameter)
        if len(wrappers) == before:
            break
    for path in paths:
        relative = path.relative_to(root).as_posix()
        source = path.read_text()
        code = masked[path]
        debug = debug_lines(source)
        patterns = [('build', build_pattern), ('present', PRESENT)]
        patterns.append(('factory-caller', re.compile(r'\b(?:self\.)?cursorConfirm\s*\.\s*(ask)\s*\(')))
        if wrappers:
            patterns.append(('caller', re.compile(r'\b(' + '|'.join(map(re.escape, sorted(wrappers))) + r')\s*\(')))
        for role, pattern in patterns:
            for match in pattern.finditer(code):
                if role == 'caller' and re.search(r'\bfunc\s*$', code[max(0, match.start()-30):match.start()]):
                    continue
                line = source.count('\n', 0, match.start()) + 1
                column = match.start() - source.rfind('\n', 0, match.start())
                if relative in exclusions or line in debug:
                    ignored[relative] += 1
                    continue
                method = match[1] if role in ('build', 'caller', 'factory-caller') else match['method'] or match['popmethod']
                key = f'{relative}:{line}:{column}:{method}'
                record = dict(file=relative, line=line, column=column, method=method)
                if role != 'build':
                    record['receiver'] = (first_argument(code, match.end()) if role == 'caller' else
                                          'cursorConfirm' if role == 'factory-caller' else
                                          match['receiver'] or match['popreceiver'])
                    enclosing = [f for f in functions if f['file'] == relative and f['body'] <= match.start() < f['end']]
                    function = max(enclosing, key=lambda f: f['start']) if enclosing else None
                    record['role'] = ('wrapper' if function and function['name'] in wrappers
                                      else role if role in ('caller', 'factory-caller') else 'physical')
                    if role == 'caller':
                        record['through'] = method
                    if function:
                        record['function'] = function['name']
                (builders if role == 'build' else sites)[key] = record
    def wrapper_path(name, seen=()):
        if name in seen:
            raise ValueError('Recursive presentation wrapper: ' + name)
        result = []
        for key, site in sites.items():
            if site.get('role') == 'wrapper' and site.get('function') == name:
                result.append(key)
                if site.get('through'):
                    result.extend(wrapper_path(site['through'], seen + (name,)))
        return sorted(set(result))
    for site in sites.values():
        if site.get('through'):
            site['wrapper_path'] = wrapper_path(site['through'])
    # CursorConfirm is a content factory as well as a presenter, not an alert
    # pass-through. Keep its physical presentation and each caller's intent separate.
    for site in sites.values():
        if site.get('role') == 'factory-caller':
            site['factory_builders'] = [key for key, value in builders.items()
                                        if value['file'] == 'Sources/Pathem/CursorConfirm.swift']
            site['presentation_path'] = [key for key, value in sites.items()
                                         if value['file'] == 'Sources/Pathem/CursorConfirm.swift'
                                         and value.get('role') == 'physical']
    return builders, sites, dict(sorted(ignored.items()))


def validate(builders, sites, manifest):
    errors = []
    for key in sorted(sites.keys() - manifest['sites'].keys()):
        errors.append('UNCLASSIFIED presentation ' + key)
    for key in sorted(manifest['sites'].keys() - sites.keys()):
        errors.append('STALE presentation ' + key)
    for key in sorted(sites.keys() & manifest['sites'].keys()):
        item = manifest['sites'][key]
        if sites[key].get('role') == 'wrapper':
            if item.get('class') is not None or item.get('role') != 'wrapper':
                errors.append('WRAPPER must remain unclassed ' + key)
            continue
        if item.get('class') not in ['A', 'B', 'C'] or not item.get('reason'):
            errors.append('UNCLASSIFIED metadata ' + key)
        if not item.get('builders') and not (item.get('builder_status') == 'unresolved' and item.get('class') == 'A'):
            errors.append('UNLINKED builder ' + key)
        for builder in item.get('builders', []):
            if builder not in builders:
                errors.append('STALE builder link ' + key + ' -> ' + builder)
        for field in ['kind', 'custom_content', 'destructive', 'default_destructive_intended']:
            if field not in item:
                errors.append('MISSING ' + field + ' ' + key)
    linked = {b for item in manifest['sites'].values() for b in item.get('builders', [])}
    for key in sorted(builders.keys() - linked):
        if not (manifest.get('unpresented_builders', {}).get(key)
                or manifest.get('implicit_builders', {}).get(key)):
            errors.append('UNPRESENTED builder requires reason ' + key)
    return errors


def render(builders, sites, ignored, manifest):
    def cell(value):
        return str(value).replace('|', '\\|').replace('\n', ' ')
    roles = collections.Counter(x.get('role', 'physical') for x in sites.values())
    implicit = manifest.get('implicit_builders', {})
    lines = ['# Transient presentation inventory', '',
             'Generated by `python3 test/transient_inventory.py --write-table` from reviewed classifications.', '',
             f'Builders: {len(builders)}. Physical expressions: {roles["physical"] + roles["wrapper"]}; '
             f'wrapper rows: {roles["wrapper"]}; resolved-through-wrapper caller rows: {roles["caller"]}; '
             f'content-factory caller rows: {roles["factory-caller"]}.',
             f'Excluded build/presentation expressions: {sum(ignored.values())}. '
             f'Implicit menu builders: {len(implicit)} (outside structural coverage for now).', '',
             '## Explicit harness file exclusions and DEBUG exclusion counts', '',
             '| File | Reason | Excluded expressions |', '|---|---|---|']
    for file in sorted(set(ignored) | set(manifest.get('exclude_files', {}))):
        reason = manifest.get('exclude_files', {}).get(file, 'Inside an explicit DEBUG branch')
        lines.append(f'| `{file}` | {cell(reason)} | {ignored.get(file, 0)} |')
    lines += ['', '## Presentation expressions and wrapper callers', '',
              '| Presentation file:line:column | Method/path | Role | Builder locations | Kind | Custom content | Destructive | Default destructive intended | Class | Evidence/reason |',
              '|---|---|---|---|---|---|---|---|---|---|']
    for key, site in sorted(sites.items()):
        item = manifest['sites'][key]
        links = ', '.join(item.get('builders', [])) or item.get('builder_status', 'unresolved')
        through = ' -> '.join(site.get('wrapper_path', []) + site.get('presentation_path', []))
        mode = site['method'] + (' through ' + through if through else '')
        values = [key, mode, site.get('role', 'physical'), links, item.get('kind', 'pass-through'),
                  item.get('custom_content', ''), item.get('destructive', ''),
                  item.get('default_destructive_intended', ''), item.get('class') or 'unclassed wrapper', item.get('reason', '')]
        lines.append('| ' + ' | '.join(cell(x) for x in values) + ' |')
    lines += ['', '## Builders without explicit presentation expressions', '',
              'Implicit menus are listed with attachment locations. They are neither called unused nor claimed covered.', '',
              '| Builder | Status / attachment provenance |', '|---|---|']
    linked = {b for item in manifest['sites'].values() for b in item.get('builders', [])}
    for key in sorted(builders.keys() - linked):
        reason = implicit.get(key) or manifest.get('unpresented_builders', {}).get(key, 'UNRESOLVED')
        lines.append(f'| {cell(key)} | {cell(reason)} |')
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scan', action='store_true', help='Read-only discovery, not classification')
    parser.add_argument('--root', type=pathlib.Path, default=ROOT)
    parser.add_argument('--manifest', type=pathlib.Path, default=MANIFEST)
    parser.add_argument('--table', type=pathlib.Path, default=TABLE)
    parser.add_argument('--write-table', action='store_true', help='Render reviewed metadata; never classify a new site')
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text()) if args.manifest.exists() else {'exclude_files': {}, 'sites': {}}
    builders, sites, ignored = scan(args.root, manifest.get('exclude_files', {}))
    if args.scan:
        print(json.dumps(dict(builders=builders, sites=sites, ignored=ignored), indent=2))
        return
    errors = validate(builders, sites, manifest)
    if ignored != manifest.get('ignored_counts', {}):
        errors.append('STALE exclusion counts; review explicit harness/DEBUG census')
    if not errors:
        table = render(builders, sites, ignored, manifest)
        if args.write_table:
            args.table.write_text(table)
        elif not args.table.exists() or args.table.read_text() != table:
            errors.append('STALE checked-in table; regenerate only after classification review')
    for error in errors:
        print(error)
    print(f'INVENTORY: builders={len(builders)} presentations={len(sites)} excluded={sum(ignored.values())}')
    print('RESULT: ' + ('FAIL' if errors else 'PASS'))
    raise SystemExit(bool(errors))


if __name__ == '__main__':
    main()
