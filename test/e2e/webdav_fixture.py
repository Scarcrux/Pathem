#!/usr/bin/env python3
"""Minimal loopback WebDAV fixture for Pathem's black-box CRUD scenario."""

import argparse
import email.utils
import html
import http.server
import pathlib
import shutil
import urllib.parse


class Handler(http.server.BaseHTTPRequestHandler):
    root: pathlib.Path

    def log_message(self, _format, *_args):
        pass

    def target(self) -> pathlib.Path:
        relative = urllib.parse.unquote(urllib.parse.urlparse(self.path).path).lstrip("/")
        target = (self.root / relative).resolve()
        if target != self.root and self.root not in target.parents:
            raise ValueError("path escaped fixture root")
        return target

    def reply(self, status: int, body: bytes = b"", content_type: str = "text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_MKCOL(self):
        try:
            self.target().mkdir(parents=False)
            self.reply(201)
        except (FileExistsError, FileNotFoundError, ValueError):
            self.reply(409)

    def do_PUT(self):
        try:
            target = self.target()
            target.parent.mkdir(parents=True, exist_ok=True)
            length = int(self.headers.get("Content-Length", "0"))
            target.write_bytes(self.rfile.read(length))
            self.reply(201)
        except ValueError:
            self.reply(400)

    def do_GET(self):
        try:
            target = self.target()
            if not target.is_file():
                self.reply(404)
                return
            self.reply(200, target.read_bytes(), "application/octet-stream")
        except ValueError:
            self.reply(400)

    def do_DELETE(self):
        try:
            target = self.target()
            if target.is_dir():
                target.rmdir()
            else:
                target.unlink()
            self.reply(204)
        except FileNotFoundError:
            self.reply(404)
        except (OSError, ValueError):
            self.reply(409)

    def do_MOVE(self):
        try:
            source = self.target()
            destination = urllib.parse.urlparse(self.headers["Destination"]).path
            relative = urllib.parse.unquote(destination).lstrip("/")
            target = (self.root / relative).resolve()
            if target != self.root and self.root not in target.parents:
                raise ValueError("destination escaped fixture root")
            if target.exists():
                self.reply(412)
                return
            source.rename(target)
            self.reply(201)
        except (KeyError, FileNotFoundError, ValueError):
            self.reply(400)

    def do_PROPFIND(self):
        try:
            target = self.target()
            if not target.is_dir():
                self.reply(404)
                return
            request_path = urllib.parse.urlparse(self.path).path
            if not request_path.endswith("/"):
                request_path += "/"
            entries = [target] + sorted(target.iterdir(), key=lambda item: item.name)
            responses = []
            for entry in entries:
                if entry == target:
                    href = request_path
                else:
                    href = request_path + urllib.parse.quote(entry.name)
                    if entry.is_dir():
                        href += "/"
                resource_type = "<d:collection/>" if entry.is_dir() else ""
                size = 0 if entry.is_dir() else entry.stat().st_size
                modified = email.utils.formatdate(entry.stat().st_mtime, usegmt=True)
                responses.append(
                    "<d:response>"
                    f"<d:href>{html.escape(href)}</d:href>"
                    "<d:propstat><d:prop>"
                    f"<d:resourcetype>{resource_type}</d:resourcetype>"
                    f"<d:getcontentlength>{size}</d:getcontentlength>"
                    f"<d:getlastmodified>{modified}</d:getlastmodified>"
                    "</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>"
                    "</d:response>"
                )
            body = (
                '<?xml version="1.0" encoding="utf-8"?>'
                '<d:multistatus xmlns:d="DAV:">' + "".join(responses) + "</d:multistatus>"
            ).encode()
            self.reply(207, body, "application/xml")
        except ValueError:
            self.reply(400)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()
    Handler.root = pathlib.Path(args.root).resolve()
    Handler.root.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    pathlib.Path(args.port_file).write_text(str(server.server_address[1]), encoding="utf-8")
    try:
        server.serve_forever()
    finally:
        server.server_close()
        shutil.rmtree(Handler.root, ignore_errors=True)


if __name__ == "__main__":
    main()
