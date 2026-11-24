"""Publish approved revisions to loopback and exercise two independent client stores."""
import functools
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "docs/themes/gallery-fixture"


def run(binary):
    with tempfile.TemporaryDirectory(prefix="pathem-shared-catalog-") as folder:
        root = Path(folder)
        public = root / "public"
        public.mkdir()
        snapshot = public / "catalog.json"
        publisher = root / "reviews.json"
        client_a = root / "client-a.json"
        client_b = root / "client-b.json"
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=public)
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            endpoint = f"http://127.0.0.1:{server.server_port}/catalog.json"

            def cli(store, *args, succeeds=True):
                result = subprocess.run([binary, store, *args], capture_output=True, timeout=20)
                assert (result.returncode == 0) == succeeds, result.stderr.decode()

            def publish():
                cli(publisher, "snapshot", snapshot)
                # Simulate multiple publications with the same Last-Modified timestamp.
                os.utime(snapshot, (1700000000, 1700000000))

            def sync_and_check(client, expected):
                cli(client, "sync", endpoint)
                store = json.loads(client.read_text())
                versions = [
                    entry["revision"]["version"] for entry in store["entries"]
                    if not entry.get("retainedOnly") and entry["revision"]["id"] not in store["withdrawn"]
                ]
                assert versions == expected, versions

            try:
                cli(publisher, "submit", FIXTURES / "v1.submission.json")
                publish()
                sync_and_check(client_a, [])
                cli(client_a, "install", "tidal-marsh", succeeds=False)
                cli(publisher, "review", "tidal-marsh", "1", "approved", "Reviewer", "Reviewed")
                publish()
                sync_and_check(client_a, [1])
                sync_and_check(client_b, [1])
                cli(client_a, "install", "tidal-marsh")
                cli(publisher, "submit", FIXTURES / "v2.submission.json")
                publish()
                sync_and_check(client_a, [1])
                cli(publisher, "review", "tidal-marsh", "2", "approved", "Reviewer", "Reviewed")
                publish()
                sync_and_check(client_a, [2])
                sync_and_check(client_b, [2])
                assert json.loads(client_a.read_text())["installed"]["tidal-marsh"]["version"] == 1
                cli(client_a, "install", "tidal-marsh")
                cli(publisher, "withdraw", "tidal-marsh")
                publish()
                sync_and_check(client_a, [])
                sync_and_check(client_b, [])
                assert json.loads(client_a.read_text())["installed"]["tidal-marsh"]["version"] == 2
                assert json.loads(client_b.read_text())["installed"] == {}
                cli(client_b, "install", "tidal-marsh", succeeds=False)

                before = client_a.read_bytes()
                snapshot.write_text('{"schemaVersion":100,"themes":[]}')
                cli(client_a, "sync", endpoint, succeeds=False)
                assert client_a.read_bytes() == before
            finally:
                server.shutdown()
                worker.join()
    print("RESULT: PASS shared theme catalog lifecycle and invalid snapshot control")


if __name__ == "__main__":
    run(Path(sys.argv[1]).resolve())
