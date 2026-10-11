#!/usr/bin/env python3
"""Incremental first-party warning gate; baseline exceptions are exact and reviewable."""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIAGNOSTIC = re.compile(r"^(.+\.swift):\d+:\d+: warning: (.+)$")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def first_party(path):
    path = Path(path)
    if not path.is_absolute():
        path = ROOT / path
    try:
        relative = path.relative_to(ROOT).as_posix()
    except ValueError:
        return None
    if relative.startswith(("Sources/", "Tests/")) and not relative.startswith("Sources/AppRelaunch/"):
        return relative
    return None


def inventory(log):
    owned, vendor, notices, unparsed = set(), set(), set(), set()
    for raw in log.splitlines():
        line = ANSI.sub("", raw)
        match = DIAGNOSTIC.match(line)
        if match:
            path, message = match.groups()
            relative = first_party(path)
            if relative:
                owned.add((relative, message))
            else:
                vendor.add(message)
        elif line.startswith("warning:"):
            notices.add(line)
        elif "warning:" in line and first_party(line.split(":", 1)[0]):
            unparsed.add(line.replace(str(ROOT) + "/", ""))
    return owned, vendor, notices, unparsed


def verdict(log, exceptions):
    owned, vendor, notices, unparsed = inventory(log)
    unknown = owned - exceptions
    return not unknown and not unparsed, owned, vendor, notices, unknown, unparsed


def self_test():
    known = "Sources/Pathem/Fixture.swift:7:2: warning: known legacy diagnostic"
    bad = "Sources/Pathem/Fixture.swift:7:2: warning: assuming you mean 'Optional<ViewFormat.GroupKey>.none'"
    exceptions = {("Sources/Pathem/Fixture.swift", "known legacy diagnostic")}
    controls = [
        ("good-build", verdict("Build complete!", set())[0]),
        ("exact-exception", verdict(known, exceptions)[0]),
        ("new-semantic-warning-red", not verdict(bad, exceptions)[0]),
        ("vendor-separated", verdict(".build/checkouts/vendor/Sources/Other.swift:7:2: warning: vendor warning", set())[0]),
        ("colored-warning-red", not verdict("\x1b[33m" + bad + "\x1b[0m", exceptions)[0]),
        ("malformed-owned-warning-red", not verdict("Sources/Pathem/Fixture.swift:7: warning: malformed", set())[0]),
    ]
    for name, ok in controls:
        print(f"WARNINGCONTROL: {'PASS' if ok else 'FAIL'} {name}")
    ok = all(ok for _, ok in controls)
    print(f"RESULT: {'PASS' if ok else 'FAIL'} ({sum(ok for _, ok in controls)}/{len(controls)})")
    return 0 if ok else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", nargs="*")
    parser.add_argument("--inventory", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--baseline", default=str(ROOT / "scripts/compiler-warning-baseline.json"))
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    if not args.logs:
        parser.error("at least one compiler log is required")
    log = "\n".join(Path(path).read_text(errors="replace") for path in args.logs)
    if args.inventory:
        owned, vendor, notices, unparsed = inventory(log)
        print(json.dumps({"first_party": [{"file": file, "message": message} for file, message in sorted(owned)], "vendor_unique": len(vendor), "notices_unique": len(notices), "unparsed_owned": sorted(unparsed)}, indent=2))
        return 1 if unparsed else 0
    baseline = json.loads(Path(args.baseline).read_text())
    entries = baseline["exceptions"]
    if any(not entry.get("reason") for entry in entries):
        parser.error("every baseline exception must explain why it remains")
    exceptions = {(entry["file"], entry["message"]) for entry in entries}
    ok, owned, vendor, notices, unknown, unparsed = verdict(log, exceptions)
    print(f"WARNINGS: owned={len(owned)} known={len(owned - unknown)} new={len(unknown)} vendor={len(vendor)} notices={len(notices)} unparsed={len(unparsed)}")
    for file, message in sorted(unknown):
        print(f"NEW WARNING: {file}: {message}")
    for line in sorted(unparsed):
        print(f"UNPARSED OWNED WARNING: {line}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
