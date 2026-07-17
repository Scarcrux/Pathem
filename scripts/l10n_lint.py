#!/usr/bin/env python3
"""Localization coverage + validity lint for Pathem.

The code is the source of truth: every user-facing string is `L("key", "English fallback")`.
This tool extracts that canonical key -> fallback map from the Swift sources and checks each
Resources/<lang>.lproj/Localizable.strings against it:

  * plutil validity (a malformed .strings silently drops every key at runtime),
  * missing keys (referenced in code but absent from the locale), and
  * stale keys (in the locale but no longer referenced in code).

Exit status is non-zero if anything is wrong, so it can gate a commit. `--fix-en` rewrites
en.lproj to exactly the canonical map (English is authoritative) and prunes stale keys from
every locale; it never invents translations for the other languages.
"""

import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = os.path.join(ROOT, "Sources")
RESOURCES = os.path.join(ROOT, "Sources", "Pathem", "Resources")
LOCALES = ["en", "fr", "de", "es", "ja", "zh-Hans"]

# Keys built at runtime from a variable -- e.g. L("menu.\(commandID)", title). Their concrete keys
# (menu.copy, toolbar.reveal, ...) can't be enumerated statically, so any locale key under these
# prefixes is treated as live: never stale, never required of the English regeneration (English
# uses the inline fallback for them).
DYNAMIC_PREFIXES = ("menu.", "toolbar.", "commander.", "acl.preset.")


def is_dynamic(key):
    return key.startswith(DYNAMIC_PREFIXES)

# The KEY of an L() call: the first string-literal argument. Lenient on purpose -- it captures the
# key even when the fallback isn't a clean literal (a comment between the args, a "a" + "b"
# concatenation), so no live key is ever mistaken for stale.
L_KEY = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)*)"')
# key + fallback for the authoritative English text. The fallback may be several string literals
# concatenated with `+` (a long message split across lines), so capture the whole run of literals
# (allowing whitespace, `+`, and line comments between them) and join them.
L_CALL = re.compile(
    r'\bL\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*'
    r'("(?:[^"\\]|\\.)*"(?:\s*(?://[^\n]*\n\s*)?\+\s*(?://[^\n]*\n\s*)?"(?:[^"\\]|\\.)*")*)'
)
STRING_LITERAL = re.compile(r'"((?:[^"\\]|\\.)*)"')
# A "key" = "value"; line in a .strings file.
STRINGS_ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)


def _swift_sources():
    for base, _, files in os.walk(SOURCES):
        if ".lproj" in base:
            continue
        for name in files:
            if name.endswith(".swift"):
                yield os.path.join(base, name)


def canonical_keys():
    """Every static L() key referenced in code (lenient; never misses a live literal key).
    Interpolated pseudo-keys like `menu.\\(commandID)` are excluded -- they aren't real keys."""
    keys = set()
    for path in _swift_sources():
        with open(path, encoding="utf-8") as handle:
            keys.update(k for k in L_KEY.findall(handle.read()) if "\\(" not in k)
    return keys


def canonical_map():
    """key -> full English fallback (concatenated literals joined), first occurrence wins."""
    result = {}
    for path in _swift_sources():
        with open(path, encoding="utf-8") as handle:
            for key, fallback_expr in L_CALL.findall(handle.read()):
                if "\\(" in key:
                    continue
                joined = "".join(unescape(part) for part in STRING_LITERAL.findall(fallback_expr))
                result.setdefault(unescape(key), joined)
    return result


# Keys whose L() fallback isn't a clean literal (concatenated / after a comment), so the extractor
# can't read the English. Provide it here so en.lproj can still be generated.
FALLBACK_OVERRIDES = {
    "bvc.spotlightOff": "Spotlight indexing is off for your files. Smart folders and search need it. "
    "In Terminal: sudo mdutil -i on /System/Volumes/Data",
}

# A straight apostrophe reads as a typographic one in UI text; keep English consistent.
def curl(text):
    return text.replace("'", "’")


def unescape(body):
    """A .strings/Swift string-literal body (as captured by the regexes) -> the real string."""
    out, i = [], 0
    simple = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'"}
    while i < len(body):
        if body[i] == "\\" and i + 1 < len(body):
            out.append(simple.get(body[i + 1], body[i + 1]))
            i += 2
        else:
            out.append(body[i])
            i += 1
    return "".join(out)


def escape(value):
    """A real string -> a .strings body (round-trips with unescape)."""
    return (
        value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
    )


def strings_path(locale):
    return os.path.join(RESOURCES, f"{locale}.lproj", "Localizable.strings")


def parse_strings(locale):
    path = strings_path(locale)
    with open(path, encoding="utf-8") as handle:
        return {unescape(k): unescape(v) for k, v in STRINGS_ENTRY.findall(handle.read())}


def plutil_ok(locale):
    path = strings_path(locale)
    return subprocess.run(
        ["plutil", "-lint", path], capture_output=True
    ).returncode == 0


def existing_header(locale):
    """The file's first /* ... */ header comment, preserved across a rewrite (nice language names)."""
    with open(strings_path(locale), encoding="utf-8") as handle:
        first = handle.readline().strip()
    return first if first.startswith("/*") and first.endswith("*/") else None


def write_strings(locale, mapping, header):
    path = strings_path(locale)
    lines = [existing_header(locale) or f"/* {header} */", ""]
    for key in sorted(mapping):
        lines.append(f'"{escape(key)}" = "{escape(mapping[key])}";')
    lines.append("")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def merge_translations(path, keys):
    """Apply a {key: {locale: text}} JSON into each locale's .strings (authoritative overwrite)."""
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    for locale in LOCALES:
        if locale == "en":
            continue
        current = parse_strings(locale)
        applied = 0
        for key, bylocale in data.items():
            if key.startswith("_") or key not in keys or locale not in bylocale:
                continue
            current[key] = bylocale[locale]
            applied += 1
        write_strings(locale, current, f"Pathem {locale} strings")
        print(f"merged {applied} translations into {locale}")


def main():
    fix_en = "--fix-en" in sys.argv
    keys = canonical_keys()
    fallbacks = canonical_map()
    print(f"canonical keys referenced in code: {len(keys)} ({len(keys) - len(fallbacks)} without a clean literal fallback)")

    for arg in sys.argv:
        if arg.startswith("--merge="):
            merge_translations(arg.split("=", 1)[1], keys)

    if fix_en:
        existing_en = parse_strings("en")
        # The code fallback is the source of truth for English (an inline change should win over a
        # stale en.lproj snapshot). Prefer it, curling apostrophes for typography; fall back to an
        # override, then any existing en value, for the few keys with no literal fallback. Stale keys
        # drop out because we only iterate the live key set.
        english = {
            key: curl(fallbacks.get(key) or FALLBACK_OVERRIDES.get(key) or existing_en.get(key) or key)
            for key in keys
        }
        write_strings("en", english, "Pathem English strings")
        for locale in LOCALES:
            if locale == "en":
                continue
            current = parse_strings(locale)
            # Keep a key if it's a live static key or a live dynamic key; drop only truly-dead ones.
            pruned = {k: v for k, v in current.items() if k in keys or is_dynamic(k)}
            if len(pruned) != len(current):
                write_strings(locale, pruned, f"Pathem {locale} strings")
        print("regenerated en.lproj and pruned truly-dead keys from every locale")

    ok = True
    for locale in LOCALES:
        if not plutil_ok(locale):
            print(f"FAIL {locale}: plutil could not parse Localizable.strings")
            ok = False
            continue
        present = set(parse_strings(locale))
        missing = keys - present
        stale = {k for k in present - keys if not is_dynamic(k)}  # dynamic keys are never stale
        status = "ok" if not missing and not stale else "GAP"
        print(f"{status:4} {locale:8} present={len(present):5} missing={len(missing):4} stale={len(stale):4}")
        if missing:
            ok = False
            for key in sorted(missing)[:8]:
                print(f"       missing: {key}")
            if len(missing) > 8:
                print(f"       ... and {len(missing) - 8} more")
        if stale:
            ok = False
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
