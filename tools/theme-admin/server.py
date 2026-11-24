#!/usr/bin/env python3
"""Private loopback dashboard backed by pathem-theme-catalog."""
import argparse
import base64
import binascii
import getpass
import hmac
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import threading
from urllib.parse import parse_qs, urlencode, urlsplit

ASSETS = Path(__file__).resolve().parent
STATES = {
    "pending": "Pending review",
    "approved": "Approved",
    "published": "Published",
    "rejected": "Rejected",
    "changesRequested": "Changes requested",
    "withdrawn": "Withdrawn",
}


class DashboardError(Exception):
    pass


def markup(text):
    return escape(str(text), quote=True)


def image_type(data):
    return "image/png" if data.startswith(b"\x89PNG\r\n\x1a\n") else "image/jpeg"


class Dashboard:
    def __init__(self, binary, store, snapshot, reviewer, password):
        self.binary = binary
        self.store = store
        self.snapshot = snapshot
        self.reviewer = reviewer
        self.password = password
        self.csrf = secrets.token_urlsafe(32)
        self.command_lock = threading.Lock()

    def cli(self, *args):
        with self.command_lock:
            result = subprocess.run(
                [self.binary, self.store, *args], capture_output=True, timeout=30, check=False
            )
        if result.returncode:
            raise DashboardError(result.stderr.decode(errors="replace").strip() or "Catalog command failed.")
        return result.stdout

    def state(self):
        state = json.loads(self.cli("state"))
        if self.snapshot.is_file():
            with self.snapshot.open("rb") as file:
                data = file.read(24 * 1024 * 1024 + 1)
            if len(data) > 24 * 1024 * 1024:
                raise DashboardError("Published snapshot exceeds its format limit.")
            published = json.loads(data)["themes"]
        else:
            published = []
        return state, {row["id"]: row["version"] for row in published}

    def submit(self, body):
        with tempfile.TemporaryDirectory(prefix="pathem-admin-") as fo:
            path = Path(fo) / "submission.json"
            path.write_bytes(body)
            self.cli("submit", path)


def status(entry, state, published):
    revision = entry["revision"]
    if published.get(revision["id"]) == revision["version"]:
        return "published"
    if revision["id"] in state["withdrawn"]:
        return "withdrawn"
    return (entry.get("review") or {}).get("outcome", "pending")


def selected_entry(state, query):
    reference = query.get("selection", [""])[0]
    return next((entry for entry in state["entries"]
                 if reference == f'{entry["revision"]["id"]}:{entry["revision"]["version"]}'), None)


def page(dashboard, query):
    state, published = dashboard.state()
    entries = sorted(state["entries"], key=lambda entry: (
        bool(entry.get("review")),
        entry["revision"]["title"].casefold(), -entry["revision"]["version"],
    ))
    search = query.get("q", [""])[0][:120]
    visible = [
        entry for entry in entries
        if all(term in " ".join(
            [entry["revision"]["title"], entry["revision"]["creator"], *entry["revision"]["tags"]]
        ).casefold() for term in search.casefold().split())
    ]
    view = query.get("view", ["pending"])[0]
    if view not in {"pending", "all"}:
        view = "pending"
    if view == "pending":
        visible = [entry for entry in visible if status(entry, state, published) == "pending"]
    selected = selected_entry(state, query) or next(iter(visible), None)
    pending = sum(status(entry, state, published) == "pending" for entry in entries)
    candidate = {}
    for entry in reversed(entries):
        revision = entry["revision"]
        if (entry.get("review") or {}).get("outcome") == "approved" and revision["id"] not in state["withdrawn"]:
            candidate[revision["id"]] = max(candidate.get(revision["id"], 0), revision["version"])
    changed = candidate != published

    links = []
    for entry in visible:
        r = entry["revision"]
        href = "/?" + urlencode({"view": view, "q": search, "selection": f'{r["id"]}:{r["version"]}'})
        current = ' aria-current="true"' if entry == selected else ""
        links.append(
            f'<a class="queue-item" href="{markup(href)}"{current}>'
            f'<strong>{markup(r["title"])}</strong><span>{markup(r["creator"])} · v{r["version"]}</span>'
            f'<span class="state">{markup(STATES[status(entry, state, published)])}</span></a>'
        )

    token = markup(dashboard.csrf)
    detail = '<div class="empty"><h2>Select a submission</h2><p>Imported revisions appear here for review.</p></div>'
    if selected:
        r = selected["revision"]
        args = urlencode({"selection": f'{r["id"]}:{r["version"]}'})
        fixed_fields = (
            f'<input type="hidden" name="csrf" value="{token}">'
            f'<input type="hidden" name="id" value="{markup(r["id"])}">'
            f'<input type="hidden" name="version" value="{r["version"]}">'
        )
        decision = selected.get("review")
        review = ""
        if decision:
            review = (
                f'<h3>Review decision</h3><p><strong>{markup(STATES[decision["outcome"]])}</strong>'
                f' by {markup(decision["reviewer"])}</p><p class="note">{markup(decision["note"])}</p>'
                f'<a href="/feedback?{markup(args)}">Download creator feedback</a>'
            )
        elif r["id"] not in state["withdrawn"]:
            review = f'''<form method="post" action="/review" class="review">
                {fixed_fields}<h3>Review decision</h3>
                <label for="review-note">Note for the creator</label>
                <textarea id="review-note" name="note" required maxlength="600" rows="3"></textarea>
                <div class="buttons">
                <button name="decision" value="approved" class="primary">Approve</button>
                <button name="decision" value="changesRequested">Request changes</button>
                <button name="decision" value="rejected">Reject</button></div></form>'''
        withdrawal = state.get("withdrawalReviews", {}).get(r["id"])
        if withdrawal:
            review += f'<p><strong>Withdrawn by {markup(withdrawal["reviewer"])}</strong> · {markup(withdrawal["note"])}</p>'
        elif r["id"] in candidate or r["id"] in published:
            review += f'''<details class="withdraw"><summary>Withdraw listing</summary>
                <form method="post" action="/withdraw">{fixed_fields}
                <label for="withdraw-note">Reason for withdrawal</label>
                <textarea id="withdraw-note" name="note" required maxlength="600" rows="2"></textarea>
                <button>Withdraw listing</button></form></details>'''
        pictures = "".join(
            f'<a href="/screenshot?{markup(args)}&amp;image={i}"><img src="/screenshot?{markup(args)}&amp;image={i}" '
            f'alt="{markup(r["title"])} screenshot {i + 1}" loading="lazy"></a>'
            for i in range(len(r["screenshots"]))
        )
        visible_version = published.get(r["id"])
        detail = f'''<section class="submission">
            <span class="state">{markup(STATES[status(selected, state, published)])}</span>
            <h2>{markup(r["title"])}</h2><p>{markup(r["summary"])}</p>
            <dl><div><dt>Creator</dt><dd>{markup(r["creator"])}</dd></div>
                <div><dt>License</dt><dd>{markup(r["license"])}</dd></div>
                <div><dt>Revision</dt><dd>v{r["version"]}</dd></div>
                <div><dt>Published revision</dt><dd>{f"v{visible_version}" if visible_version else "None"}</dd></div>
                <div><dt>Listing ID</dt><dd>{markup(r["id"])}</dd></div>
                {f'<div><dt>Source</dt><dd>{markup(r["source"])}</dd></div>' if r.get("source") else ""}
            </dl><p>{markup(" · ".join(r["tags"]))}</p>
            <div class="screenshots">{pictures}</div>
            <a class="package" href="/theme?{markup(args)}">Download theme for Pathem preview</a>
            {review}</section>'''
    publish_state = "Approved changes are ready to publish." if changed else "Snapshot is up to date."
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Marketplace Admin · Pathem</title><link rel="stylesheet" href="/style.css">
        <script src="/upload.js" defer></script></head><body>
        <header><div><strong>Pathem</strong><span>Marketplace Admin</span></div>
        <span>{markup(dashboard.reviewer)}</span></header>
        <main><div class="heading"><div><h1>Theme review</h1><p>{pending} pending · {len(published)} published</p></div>
        <form id="submission-upload" data-csrf="{token}">
        <label for="submission-file">Import submission</label>
        <input id="submission-file" type="file" accept=".json,application/json" required><button>Import</button>
        <output id="upload-status" role="status"></output></form></div>
        <section class="publish"><p>{publish_state}</p>
        <form method="post" action="/publish"><input type="hidden" name="csrf" value="{token}">
        <button class="primary"{"" if changed else " disabled"}>Publish snapshot</button></form></section>
        <div class="workspace"><aside><nav aria-label="Submissions">
        <a href="/?view=pending" {"aria-current=page" if view == "pending" else ""}>Pending</a>
        <a href="/?view=all" {"aria-current=page" if view == "all" else ""}>All revisions</a></nav>
        <form method="get" class="search"><input type="hidden" name="view" value="{view}">
        <label for="queue-search">Find a submission</label>
        <input id="queue-search" type="search" name="q" value="{markup(search)}"><button>Search</button></form>
        {"".join(links) or '<p class="empty">No matching submissions.</p>'}</aside>
        {detail}</div></main></body></html>'''


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Review notes and credentials do not enter access logs.

    @property
    def dashboard(self):
        return self.server.dashboard

    def send(self, result, content=b"", media="text/plain; charset=utf-8", headers=()):
        self.send_response(result)
        self.send_header("Content-Type", media)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'; form-action 'self'; base-uri 'none'")
        for key, value in headers:
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(content)

    def allowed(self):
        if self.headers.get("Host") != f"127.0.0.1:{self.server.server_port}":
            self.send(403, b"Invalid dashboard host.")
            return False
        scheme, _, token = self.headers.get("Authorization", "").partition(" ")
        try:
            credential = base64.b64decode(token, validate=True) if scheme == "Basic" else b""
        except (ValueError, binascii.Error):
            credential = b""
        if hmac.compare_digest(credential, f"reviewer:{self.dashboard.password}".encode()):
            return True
        self.send(401, b"Reviewer sign-in required.",
                  headers=(("WWW-Authenticate", 'Basic realm="Pathem Marketplace", charset="UTF-8"'),))
        return False

    def do_GET(self):
        if not self.allowed():
            return
        parsed = urlsplit(self.path)
        query = parse_qs(parsed.query)
        try:
            if parsed.path == "/":
                self.send(200, page(self.dashboard, query).encode(), "text/html; charset=utf-8")
                return
            assets = {"/style.css": "text/css", "/upload.js": "text/javascript"}
            if parsed.path in assets:
                self.send(200, (ASSETS / parsed.path[1:]).read_bytes(), assets[parsed.path])
                return
            if parsed.path in ("/theme", "/screenshot", "/feedback"):
                state, _ = self.dashboard.state()
                entry = selected_entry(state, query)
                if entry:
                    r = entry["revision"]
                    if parsed.path == "/theme":
                        self.send(200, base64.b64decode(r["package"]), "application/json",
                                  (("Content-Disposition", f'attachment; filename="{r["id"]}-v{r["version"]}.json"'),))
                        return
                    if parsed.path == "/screenshot":
                        number = int(query.get("image", ["0"])[0])
                        if 0 <= number < len(r["screenshots"]):
                            data = base64.b64decode(r["screenshots"][number])
                            self.send(200, data, image_type(data))
                            return
                    if parsed.path == "/feedback" and entry.get("review"):
                        review = entry["review"]
                        note = f'{r["title"]} v{r["version"]}\n{STATES[review["outcome"]]}\n\n{review["note"]}\n'
                        self.send(200, note.encode(), headers=(
                            ("Content-Disposition", f'attachment; filename="{r["id"]}-v{r["version"]}-feedback.txt"'),))
                        return
            self.send(404, b"Page not found.")
        except (OSError, subprocess.SubprocessError, DashboardError, ValueError, KeyError, TypeError):
            self.send(500, b"Could not read the catalog.")

    def do_POST(self):
        if not self.allowed():
            return
        path = urlsplit(self.path).path
        if self.headers.get("Origin") != f"http://127.0.0.1:{self.server.server_port}":
            self.send(403, b"Invalid request origin.")
            return
        try:
            count = int(self.headers.get("Content-Length", "-1"))
            if not 0 < count <= (9 * 1024 * 1024 if path == "/submit" else 4096):
                self.send(413, b"Request exceeds the size limit.")
                return
            body = self.rfile.read(count)
            fields = {} if path == "/submit" else parse_qs(body.decode("utf-8"))
            token = self.headers.get("X-CSRF-Token", "") if path == "/submit" else fields.get("csrf", [""])[0]
            if not hmac.compare_digest(token.encode(), self.dashboard.csrf.encode()):
                self.send(403, b"Invalid form token.")
                return
            if path == "/submit":
                self.dashboard.submit(body)
                self.send(201, b"Submission queued for review.")
                return
            if path == "/review":
                self.dashboard.cli("review", fields["id"][0], fields["version"][0],
                                   fields["decision"][0], self.dashboard.reviewer, fields["note"][0].strip())
            elif path == "/withdraw":
                self.dashboard.cli("withdraw", fields["id"][0], self.dashboard.reviewer, fields["note"][0].strip())
            elif path == "/publish":
                self.dashboard.cli("snapshot", self.dashboard.snapshot)
            else:
                self.send(404, b"Page not found.")
                return
            self.send(303, headers=(("Location", "/?view=all"),))
        except DashboardError as error:
            self.send(400, str(error).encode())
        except (KeyError, ValueError, OSError, subprocess.SubprocessError):
            self.send(400, b"Could not process the request.")


def make_server(dashboard, port=0):
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.dashboard = dashboard
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog-tool", required=True, type=Path)
    parser.add_argument("--store", required=True, type=Path)
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--reviewer", required=True)
    parser.add_argument("--port", type=int, default=8789)
    args = parser.parse_args()
    if args.store.resolve() == args.snapshot.resolve():
        parser.error("The review store and published snapshot must use separate files.")
    os.umask(0o077)
    password = getpass.getpass("Local reviewer password: ")
    if not password:
        parser.error("A password is required.")
    with make_server(Dashboard(args.catalog_tool.resolve(), args.store.resolve(),
                               args.snapshot.resolve(), args.reviewer, password), args.port) as server:
        print(f"Marketplace Admin at http://127.0.0.1:{server.server_port}/", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
