"""Exercise private dashboard actions against the real Swift catalog publisher."""
import base64
import http.client
import importlib.util
import json
from pathlib import Path
import secrets
import sys
import tempfile
import threading
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "docs/themes/gallery-fixture"
spec = importlib.util.spec_from_file_location("theme_admin", ROOT / "tools/theme-admin/server.py")
admin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(admin)


def check_image_types():
    box = lambda major, *compatible: (
        (16 + 4 * len(compatible)).to_bytes(4, "big") + b"ftyp" + major + bytes(4) + b"".join(compatible) + b"mdat"
    )
    for data, expected in [
        (b"\x89PNG\r\n\x1a\n" + bytes(8), "image/png"),
        (b"\xff\xd8\xff\xe0" + bytes(8), "image/jpeg"),
        (box(b"heic", b"mif1", b"heic"), "image/heic"),
        (box(b"heix"), "image/heic"),
        (box(b"mif1", b"mif1", b"heic"), "image/heic"),
        (box(b"msf1"), "image/heic"),
        (box(b"avif", b"mif1", b"miaf"), "application/octet-stream"),
        (box(b"avis"), "application/octet-stream"),
        (box(b"isom"), "application/octet-stream"),
        (b"GIF89a" + bytes(8), "application/octet-stream"),
        (b"", "application/octet-stream"),
    ]:
        assert admin.image_type(data) == expected, (data[:20], admin.image_type(data))


def run(binary):
    check_image_types()
    with tempfile.TemporaryDirectory(prefix="pathem-theme-admin-") as directory:
        root = Path(directory)
        private = root / "reviews.json"
        public = root / "catalog.json"
        password = secrets.token_urlsafe(24)
        dashboard = admin.Dashboard(binary, private, public, "Fixture reviewer", password)
        with admin.make_server(dashboard) as server:
            worker = threading.Thread(target=server.serve_forever)
            worker.start()
            origin = f"http://127.0.0.1:{server.server_port}"
            authorization = "Basic " + base64.b64encode(f"reviewer:{password}".encode()).decode()

            def request(path, body=None, expected=200, *, auth=True, same_origin=True, headers=None):
                fields = dict(headers or {})
                if auth:
                    fields["Authorization"] = authorization
                if body is not None and same_origin:
                    fields["Origin"] = origin
                conn = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=30)
                try:
                    conn.request("POST" if body is not None else "GET", path, body, fields)
                    response = conn.getresponse()
                    payload = response.read()
                    assert response.status == expected, (path, response.status, payload[:300])
                    return payload
                finally:
                    conn.close()

            def post(path, expected=303, **fields):
                return request(path, urlencode({"csrf": dashboard.csrf, **fields}), expected=expected)

            def submit(version):
                data = (FIXTURES / f"v{version}.submission.json").read_bytes()
                request("/submit", data, expected=201, headers={"X-CSRF-Token": dashboard.csrf})

            try:
                request("/", expected=401, auth=False)
                request("/", expected=403, headers={"Host": "outside.invalid"})
                request("/publish", "csrf=wrong", expected=403)
                request("/publish", urlencode({"csrf": dashboard.csrf}), expected=403, same_origin=False)
                assert not public.exists()
                assert b"No matching submissions" in request("/")
                submit(1)
                assert b"Tidal Marsh" in request("/?q=marsh")
                assert b"No matching submissions" in request("/?q=no-match")
                first = "/?selection=tidal-marsh%3A1"
                assert b"Pending review" in request(first)
                shot = request("/screenshot?selection=tidal-marsh%3A1&image=0")
                assert admin.image_type(shot) in ("image/heic", "image/png", "image/jpeg"), shot[:16]
                if shot[4:8] == b"ftyp":
                    assert shot[8:12] in (b"heic", b"heix"), shot[:16]
                assert json.loads(request("/theme?selection=tidal-marsh%3A1"))["schemaVersion"] >= 1
                post("/review", id="tidal-marsh", version=1, decision="approved", note="Approved fixture")
                assert not public.exists()
                post("/publish")
                assert json.loads(public.read_text())["themes"][0]["version"] == 1
                submit(2)
                assert b"Published revision</dt><dd>v1" in request("/?selection=tidal-marsh%3A2")
                post("/review", id="tidal-marsh", version=2, decision="changesRequested", note="Keep the caption")
                assert b"Keep the caption" in request("/feedback?selection=tidal-marsh%3A2")
                assert b"Changes requested" in request("/?view=all&selection=tidal-marsh%3A2")
                assert json.loads(public.read_text())["themes"][0]["version"] == 1
                data = json.loads((FIXTURES / "v2.submission.json").read_bytes())
                data["version"] = 3
                request("/submit", json.dumps(data), expected=201, headers={"X-CSRF-Token": dashboard.csrf})
                post("/review", id="tidal-marsh", version=3, decision="approved", note="Approved revision")
                post("/publish")
                assert json.loads(public.read_text())["themes"][0]["version"] == 3
                assert b"Approved revision" not in public.read_bytes()
                post("/withdraw", id="tidal-marsh", note="Withdrawn fixture")
                assert json.loads(public.read_text())["themes"][0]["version"] == 3
                post("/publish")
                assert json.loads(public.read_text())["themes"] == []
                assert json.loads(private.read_text())["withdrawalReviews"]["tidal-marsh"]["reviewer"] == "Fixture reviewer"
                assert b"Withdrawn" in request("/?view=all&selection=tidal-marsh%3A3")
            finally:
                server.shutdown()
                worker.join()
    print("RESULT: PASS private theme admin review, update, publication, and withdrawal")


if __name__ == "__main__":
    run(Path(sys.argv[1]).resolve())
