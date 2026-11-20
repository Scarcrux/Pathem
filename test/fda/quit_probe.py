"""Exercise PID-targeted AppKit Quit with the production FDA guide in an isolated app."""
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]


def main():
    with tempfile.TemporaryDirectory(prefix="pathem-fda-quit-") as temp:
        scratch = Path(temp)
        config = scratch / "config"
        config.mkdir()
        bundle = scratch / "FDAProbe.app"
        contents = bundle / "Contents"
        executable = contents / "MacOS" / "FDAProbe"
        executable.parent.mkdir(parents=True)
        identity = f"org.example.pathem-fda-probe.{uuid.uuid4().hex}"
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": executable.name,
            "CFBundleIdentifier": identity,
            "CFBundlePackageType": "APPL",
        }))
        subprocess.run([
            "xcrun", "--toolchain", "XcodeDefault", "swiftc", "-D", "DEBUG",
            str(ROOT / "Sources/Pathem/FullDiskAccessGuide.swift"),
            str(ROOT / "test/fda/main.swift"), "-o", str(executable),
        ], check=True, timeout=60)
        env = dict(os.environ, PATHEM_CONFIG_DIR=str(config),
                   PATHEM_TRANSIENT_SURFACES_TEST="1", FDA_PROBE_BUNDLE=str(bundle))
        try:
            for reopen in (False, True):
                run_case(executable, env, scratch / "receipt", reopen)
        finally:
            subprocess.run(["defaults", "delete", identity], capture_output=True, timeout=5)


def run_case(executable, env, receipt, reopen):
    args = [str(executable), "--reopen"] if reopen else [str(executable)]
    with receipt.open("w") as log, subprocess.Popen(
        args, env=env, stdout=log, stderr=subprocess.STDOUT
    ) as app:
        try:
            deadline = time.monotonic() + 8
            while f"READY {app.pid} " not in receipt.read_text() and app.poll() is None:
                if time.monotonic() >= deadline:
                    raise RuntimeError("Scratch app did not report readiness")
                time.sleep(0.05)
            subprocess.run([str(executable), "--quit", str(app.pid)], env=env, check=True, timeout=5)
            try:
                status = app.wait(timeout=5)
            except subprocess.TimeoutExpired as error:
                raise RuntimeError(f"PID-targeted Quit did not exit:\n{receipt.read_text()}") from error
            verdict = receipt.read_text()
            if status or f"READY {app.pid} sheet=false child=true" not in verdict:
                raise RuntimeError(f"Nonmodal guide check failed: {verdict}")
            if f"TERMINATED dismissed={str(reopen).lower()}" not in verdict:
                raise RuntimeError(f"Unexpected dismissal state: {verdict}")
            if reopen and "REOPENED" not in verdict:
                raise RuntimeError("Guide did not reopen")
            print(verdict, end="", flush=True)
        finally:
            if app.poll() is None:
                app.kill()
                app.wait(timeout=5)


if __name__ == "__main__":
    main()
