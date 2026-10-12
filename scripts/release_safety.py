#!/usr/bin/env python3
"""Read-only, redacted candidate-tree/all-ref release safety gate; never publishes."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

POLICY = Path(__file__).with_name("release-safety.toml")
NOREPLY = re.compile(r"(?:[a-z0-9][a-z0-9+._\[\]-]*@users\.noreply\.github\.com|noreply@github\.com)\Z", re.I)
COMMIT = re.compile(r"[0-9a-f]{40}(?:[0-9a-f]{24})?\Z")


class SafetyFailure(Exception):
    """Only fixed, non-sensitive messages may escape this boundary."""


def git(repo, *args):
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, timeout=30)
    if result.returncode:
        raise SafetyFailure("git inspection failed (details withheld)")
    return result.stdout


def ref_snapshot(repo):
    return git(repo, "rev-parse", "HEAD") + git(repo, "for-each-ref", "--format=%(refname)%00%(objectname)")


def candidates(repo):
    names = git(repo, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
    return sorted(set(os.fsdecode(name) for name in names.split(b"\0") if name))


def file_bytes(path):
    if path.is_symlink():
        return os.fsencode(os.readlink(path))  # inspect the committed link, never its external target
    if not path.is_file():
        raise SafetyFailure("candidate file absent or not regular (path withheld)")
    return path.read_bytes()


def tree_snapshot(repo, destination):
    fingerprints = {}
    for name in candidates(repo):
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise SafetyFailure("unsafe candidate path (path withheld)")
        data = file_bytes(repo / relative)
        fingerprints[name] = hashlib.sha256(data).digest()
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(0o600)
    if not fingerprints:
        raise SafetyFailure("empty candidate tree")
    return fingerprints


def validate_report(status, data):
    if status not in (0, 1) or not isinstance(data, list):
        raise SafetyFailure("scanner failed or invalid report (details withheld)")
    if (status == 0) != (len(data) == 0):
        raise SafetyFailure("scanner exit/report mismatch")
    for finding in data:
        if not isinstance(finding, dict) or finding.get("Secret") != "REDACTED":
            raise SafetyFailure("scanner report missing full secret redaction")
        if not isinstance(finding.get("RuleID"), str) or not finding["RuleID"]:
            raise SafetyFailure("scanner report missing rule identity")
    return data


def scan(scanner, mode, target, scratch):
    report = scratch / (mode + "-report.json")
    report.touch(mode=0o600)
    ignore = scratch / "empty-ignore"
    ignore.touch(mode=0o600)
    command = [scanner, mode, str(target), "--config", str(POLICY), "--redact=100",
               "--no-banner", "--no-color", "--report-format", "json", "--report-path", str(report),
               "--gitleaks-ignore-path", str(ignore), "--ignore-gitleaks-allow", "--timeout", "90"]
    if mode == "git":
        command += ["--log-opts=--all"]
    result = subprocess.run(command, capture_output=True, timeout=100)
    # Never relay scanner logs/snippets/paths/author metadata, even when the tool fails.
    try:
        data = json.loads(report.read_bytes())
    except (ValueError, OSError):
        raise SafetyFailure("scanner produced no valid JSON report") from None
    return validate_report(result.returncode, data)


def authors(repo):
    records = git(repo, "log", "--all", "--format=%H%x00%an%x00%ae%x00%cn%x00%ce")
    failures = Counter()
    commits = set()
    count = 0
    for record in records.decode("utf-8", errors="strict").splitlines():
        fields = record.split("\0")
        if len(fields) != 5 or not COMMIT.fullmatch(fields[0]):
            raise SafetyFailure("invalid history metadata (details withheld)")
        count += 1
        for role, name, email in [("author", fields[1], fields[2]), ("committer", fields[3], fields[4])]:
            if not NOREPLY.fullmatch(email):
                failures[role + "-email"] += 1
                commits.add(fields[0])
            # This is a review boundary, not proof that every spaced name is a real person.
            if (not name or any(c.isspace() for c in name)) and name not in {"GitHub Actions"}:
                failures[role + "-name-review"] += 1
                commits.add(fields[0])
    if not count:
        raise SafetyFailure("empty history")
    return count, failures, commits


def summarise(scope, findings):
    counts = Counter(f["RuleID"] if f["RuleID"] in {"personal-email-address", "absolute-user-path"}
                     else "credential-pattern" for f in findings)
    print(f"RELEASESAFETY: {'FAIL' if findings else 'PASS'} {scope} findings={len(findings)}")
    for rule, count in sorted(counts.items()):
        print(f"RELEASESAFETY: {scope} rule={rule} count={count}")
    ids = sorted({f.get("Commit", "") for f in findings if COMMIT.fullmatch(f.get("Commit", ""))})
    for commit in ids[:8]:
        print(f"RELEASESAFETY: {scope} review-commit={commit}")


def audit(repo, scanner):
    repo = repo.resolve()
    if not shutil.which(scanner):
        raise SafetyFailure("gitleaks unavailable; install it before release")
    if git(repo, "rev-parse", "--is-shallow-repository").strip() != b"false":
        raise SafetyFailure("shallow history cannot establish release safety")
    refs = ref_snapshot(repo)
    with tempfile.TemporaryDirectory(prefix="pathem-release-safety-") as temporary:
        scratch = Path(temporary)
        scratch.chmod(0o700)
        tree = scratch / "candidate-tree"
        tree.mkdir(mode=0o700)
        fingerprints = tree_snapshot(repo, tree)
        current = scan(scanner, "dir", tree, scratch)
        history = scan(scanner, "git", repo, scratch)
        commit_count, metadata, review_ids = authors(repo)
        if ref_snapshot(repo) != refs or candidates(repo) != sorted(fingerprints):
            raise SafetyFailure("repository changed during scan; rerun on stable input")
        if any(hashlib.sha256(file_bytes(repo / name)).digest() != digest
               for name, digest in fingerprints.items()):
            raise SafetyFailure("candidate content changed during scan; rerun")
        print(f"RELEASESAFETY: delivered candidate-files={len(fingerprints)} history-commits={commit_count}")
        summarise("candidate-tree", current)
        summarise("all-ref-history", history)
        print(f"RELEASESAFETY: {'FAIL' if metadata else 'PASS'} authorship findings={sum(metadata.values())}")
        for rule, count in sorted(metadata.items()):
            print(f"RELEASESAFETY: authorship rule={rule} count={count}")
        for commit in sorted(review_ids)[:8]:
            print(f"RELEASESAFETY: authorship review-commit={commit}")
        passed = not current and not history and not metadata
        print("RELEASESAFETY: LIMIT bounded patterns only; manual identity/branding review still required")
        print(f"RESULT: {'PASS' if passed else 'FAIL'} release safety")
        return 0 if passed else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--scanner", default="gitleaks")
    args = parser.parse_args()
    try:
        return audit(args.repo, args.scanner)
    except SafetyFailure as error:
        print(f"RESULT: FAIL release safety: {error}")
    except (OSError, subprocess.TimeoutExpired, UnicodeError, TypeError):
        print("RESULT: FAIL release safety: execution/I/O/timeout/schema error (details withheld)")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
