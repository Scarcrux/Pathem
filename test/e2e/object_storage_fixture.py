#!/usr/bin/env python3
"""Hermetic HTTPS fixture for Pathem's S3 and Azure Blob product checks."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import html
from pathlib import Path
import shutil
import ssl
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, parse_qsl, quote, unquote, urlsplit


MODIFIED_ISO = "2026-01-02T03:04:05Z"
MODIFIED_HTTP = "Fri, 02 Jan 2026 03:04:05 GMT"
S3_ACCESS_KEY = "e2e-access"
S3_SECRET = "e2e-secret"
AZURE_ACCOUNT = "devstoreaccount1"
AZURE_KEY = b"e2e-azure-key"


def safe_path(root: Path, *parts: str) -> Path:
    candidate = root.joinpath(*(part for part in parts if part)).resolve()
    resolved_root = root.resolve()
    if candidate != resolved_root and resolved_root not in candidate.parents:
        raise ValueError("path escapes fixture root")
    return candidate


class ObjectStorageHandler(BaseHTTPRequestHandler):
    server_version = "PathemObjectStorageFixture/1"

    def log_message(self, _format: str, *_args: object) -> None:
        return

    @property
    def fixture_root(self) -> Path:
        return self.server.fixture_root  # type: ignore[attr-defined]

    def protocol(self) -> str | None:
        authorization = self.headers.get("Authorization", "")
        if authorization.startswith("AWS4-HMAC-SHA256") and self.valid_aws_signature(authorization):
            return "s3"
        if authorization.startswith("SharedKey ") and self.valid_azure_signature(authorization):
            return "azure"
        return None

    def valid_aws_signature(self, authorization: str) -> bool:
        try:
            fields = dict(
                item.strip().split("=", 1)
                for item in authorization.removeprefix("AWS4-HMAC-SHA256 ").split(",")
            )
            credential = fields["Credential"].split("/")
            if len(credential) != 5 or credential[0] != S3_ACCESS_KEY:
                return False
            date, region, service, terminal = credential[1:]
            if service != "s3" or terminal != "aws4_request":
                return False
            signed_names = fields["SignedHeaders"].split(";")
            canonical_headers = ""
            for name in signed_names:
                value = self.headers.get(name)
                if value is None:
                    return False
                canonical_headers += f"{name}:{' '.join(value.strip().split())}\n"

            parsed = urlsplit(self.path)
            canonical_uri = quote(unquote(parsed.path), safe="/-_.~")
            canonical_query = "&".join(
                f"{quote(name, safe='-_.~')}={quote(value, safe='-_.~')}"
                for name, value in sorted(parse_qsl(parsed.query, keep_blank_values=True))
            )
            payload_hash = self.headers.get("x-amz-content-sha256")
            if payload_hash is None:
                return False
            canonical_request = "\n".join(
                [
                    self.command,
                    canonical_uri,
                    canonical_query,
                    canonical_headers,
                    fields["SignedHeaders"],
                    payload_hash,
                ]
            )
            timestamp = self.headers["x-amz-date"]
            scope = "/".join([date, region, service, terminal])
            string_to_sign = "\n".join(
                [
                    "AWS4-HMAC-SHA256",
                    timestamp,
                    scope,
                    hashlib.sha256(canonical_request.encode()).hexdigest(),
                ]
            )
            key_date = hmac.new(("AWS4" + S3_SECRET).encode(), date.encode(), hashlib.sha256).digest()
            key_region = hmac.new(key_date, region.encode(), hashlib.sha256).digest()
            key_service = hmac.new(key_region, service.encode(), hashlib.sha256).digest()
            signing_key = hmac.new(key_service, terminal.encode(), hashlib.sha256).digest()
            expected = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()
            return hmac.compare_digest(expected, fields["Signature"])
        except (KeyError, ValueError):
            return False

    def valid_azure_signature(self, authorization: str) -> bool:
        try:
            account, supplied = authorization.removeprefix("SharedKey ").split(":", 1)
            if account != AZURE_ACCOUNT:
                return False
            content_length = int(self.headers.get("Content-Length", "0"))
            standard = [
                self.headers.get("Content-Encoding", ""),
                self.headers.get("Content-Language", ""),
                "" if content_length == 0 else str(content_length),
                self.headers.get("Content-MD5", ""),
                self.headers.get("Content-Type", ""),
                "",
                self.headers.get("If-Modified-Since", ""),
                self.headers.get("If-Match", ""),
                self.headers.get("If-None-Match", ""),
                self.headers.get("If-Unmodified-Since", ""),
                self.headers.get("Range", ""),
            ]
            xms = []
            for name, value in self.headers.items():
                lowered = name.lower()
                if lowered.startswith("x-ms-"):
                    xms.append((lowered, " ".join(value.strip().split())))
            canonical_headers = "".join(f"{name}:{value}\n" for name, value in sorted(xms))
            parsed = urlsplit(self.path)
            grouped: dict[str, list[str]] = {}
            for name, value in parse_qsl(parsed.query, keep_blank_values=True):
                grouped.setdefault(name.lower(), []).append(value)
            canonical_resource = f"/{account}{parsed.path}"
            for name in sorted(grouped):
                canonical_resource += f"\n{name}:{','.join(grouped[name])}"
            string_to_sign = self.command + "\n" + "\n".join(standard) + "\n"
            string_to_sign += canonical_headers + canonical_resource
            expected = base64.b64encode(
                hmac.new(AZURE_KEY, string_to_sign.encode(), hashlib.sha256).digest()
            ).decode()
            return hmac.compare_digest(expected, supplied)
        except (KeyError, ValueError):
            return False

    def send_bytes(self, status: int, body: bytes = b"", content_type: str = "text/plain") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def request_parts(self) -> tuple[str, list[str], dict[str, list[str]]]:
        parsed = urlsplit(self.path)
        parts = [unquote(part) for part in parsed.path.split("/") if part]
        return parsed.path, parts, parse_qs(parsed.query, keep_blank_values=True)

    def do_GET(self) -> None:
        protocol = self.protocol()
        if protocol is None:
            self.send_bytes(403, b"signed authorization required")
            return
        try:
            if protocol == "s3":
                self.s3_get()
            else:
                self.azure_get()
        except ValueError as error:
            self.send_bytes(400, str(error).encode())

    def do_PUT(self) -> None:
        protocol = self.protocol()
        if protocol is None:
            self.send_bytes(403, b"signed authorization required")
            return
        try:
            if protocol == "s3":
                self.s3_put()
            else:
                self.azure_put()
        except ValueError as error:
            self.send_bytes(400, str(error).encode())

    def do_DELETE(self) -> None:
        protocol = self.protocol()
        if protocol is None:
            self.send_bytes(403, b"signed authorization required")
            return
        try:
            if protocol == "s3":
                self.s3_delete()
            else:
                self.azure_delete()
        except ValueError as error:
            self.send_bytes(400, str(error).encode())

    def read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0"))
        return self.rfile.read(length) if length else b""

    def s3_get(self) -> None:
        _path, parts, query = self.request_parts()
        if not parts:
            self.send_bytes(404)
            return
        bucket, *key_parts = parts
        bucket_root = safe_path(self.fixture_root / "s3", bucket)
        if "list-type" in query:
            prefix = query.get("prefix", [""])[0]
            self.send_bytes(200, self.s3_listing(bucket_root, prefix), "application/xml")
            return
        target = safe_path(bucket_root, *key_parts)
        if not target.is_file():
            self.send_bytes(404, b"NoSuchKey")
            return
        self.send_bytes(200, target.read_bytes(), "application/octet-stream")

    def s3_put(self) -> None:
        _path, parts, _query = self.request_parts()
        if len(parts) < 2:
            self.send_bytes(400, b"bucket and key required")
            return
        bucket, *key_parts = parts
        target = safe_path(self.fixture_root / "s3", bucket, *key_parts)
        copy_source = self.headers.get("x-amz-copy-source")
        if copy_source:
            source_parts = [unquote(part) for part in urlsplit(copy_source).path.split("/") if part]
            source = safe_path(self.fixture_root / "s3", *source_parts)
            if not source.is_file():
                self.send_bytes(404, b"NoSuchKey")
                return
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        elif urlsplit(self.path).path.endswith("/"):
            target.mkdir(parents=True, exist_ok=True)
            self.read_body()
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(self.read_body())
        self.send_bytes(200)

    def s3_delete(self) -> None:
        path, parts, _query = self.request_parts()
        if len(parts) < 2:
            self.send_bytes(400)
            return
        bucket, *key_parts = parts
        target = safe_path(self.fixture_root / "s3", bucket, *key_parts)
        if path.endswith("/"):
            if target.is_dir() and not any(target.iterdir()):
                target.rmdir()
        elif target.is_file():
            target.unlink()
        self.send_bytes(204)

    def s3_listing(self, bucket_root: Path, prefix: str) -> bytes:
        target = safe_path(bucket_root, *[part for part in prefix.split("/") if part])
        contents: list[str] = []
        prefixes: list[str] = []
        if prefix and target.is_dir():
            contents.append(
                f"<Contents><Key>{html.escape(prefix)}</Key><Size>0</Size>"
                f"<LastModified>{MODIFIED_ISO}</LastModified></Contents>"
            )
        if target.is_dir():
            for child in sorted(target.iterdir(), key=lambda item: item.name):
                key = prefix + child.name
                if child.is_dir():
                    prefixes.append(f"<CommonPrefixes><Prefix>{html.escape(key)}/</Prefix></CommonPrefixes>")
                else:
                    contents.append(
                        f"<Contents><Key>{html.escape(key)}</Key><Size>{child.stat().st_size}</Size>"
                        f"<LastModified>{MODIFIED_ISO}</LastModified></Contents>"
                    )
        xml = (
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            "<ListBucketResult>"
            + "".join(contents)
            + "".join(prefixes)
            + "<IsTruncated>false</IsTruncated></ListBucketResult>"
        )
        return xml.encode()

    def azure_get(self) -> None:
        _path, parts, query = self.request_parts()
        azure_root = self.fixture_root / "azure"
        if query.get("comp") == ["list"] and not parts:
            self.send_bytes(200, self.azure_containers(azure_root), "application/xml")
            return
        if not parts:
            self.send_bytes(404)
            return
        container, *key_parts = parts
        container_root = safe_path(azure_root, container)
        if query.get("comp") == ["list"] and query.get("restype") == ["container"]:
            prefix = query.get("prefix", [""])[0]
            self.send_bytes(200, self.azure_listing(container_root, prefix), "application/xml")
            return
        target = safe_path(container_root, *key_parts)
        if not target.is_file():
            self.send_bytes(404, b"BlobNotFound")
            return
        self.send_bytes(200, target.read_bytes(), "application/octet-stream")

    def azure_put(self) -> None:
        path, parts, query = self.request_parts()
        if not parts:
            self.send_bytes(400)
            return
        azure_root = self.fixture_root / "azure"
        container, *key_parts = parts
        target = safe_path(azure_root, container, *key_parts)
        if query.get("restype") == ["container"] and not key_parts:
            target.mkdir(parents=True, exist_ok=True)
            self.read_body()
        else:
            copy_source = self.headers.get("x-ms-copy-source")
            if copy_source:
                source_parts = [
                    unquote(part) for part in urlsplit(copy_source).path.split("/") if part
                ]
                source = safe_path(azure_root, *source_parts)
                if not source.is_file():
                    self.send_bytes(404, b"BlobNotFound")
                    return
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
            elif path.endswith("/"):
                target.mkdir(parents=True, exist_ok=True)
                self.read_body()
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(self.read_body())
        self.send_bytes(201)

    def azure_delete(self) -> None:
        path, parts, query = self.request_parts()
        if not parts:
            self.send_bytes(400)
            return
        azure_root = self.fixture_root / "azure"
        container, *key_parts = parts
        target = safe_path(azure_root, container, *key_parts)
        if query.get("restype") == ["container"] and not key_parts:
            if target.is_dir() and not any(target.iterdir()):
                target.rmdir()
            elif target.exists():
                self.send_bytes(409, b"ContainerNotEmpty")
                return
        elif path.endswith("/"):
            if target.is_dir() and not any(target.iterdir()):
                target.rmdir()
        elif target.is_file():
            target.unlink()
        self.send_bytes(202)

    def azure_containers(self, azure_root: Path) -> bytes:
        rows = []
        if azure_root.is_dir():
            for child in sorted(azure_root.iterdir(), key=lambda item: item.name):
                if child.is_dir():
                    rows.append(
                        f"<Container><Name>{html.escape(child.name)}</Name><Properties>"
                        f"<Last-Modified>{MODIFIED_HTTP}</Last-Modified></Properties></Container>"
                    )
        return (
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            "<EnumerationResults><Containers>"
            + "".join(rows)
            + "</Containers><NextMarker /></EnumerationResults>"
        ).encode()

    def azure_listing(self, container_root: Path, prefix: str) -> bytes:
        target = safe_path(container_root, *[part for part in prefix.split("/") if part])
        blobs: list[str] = []
        prefixes: list[str] = []
        if prefix and target.is_dir():
            blobs.append(
                f"<Blob><Name>{html.escape(prefix)}</Name><Properties>"
                f"<Last-Modified>{MODIFIED_HTTP}</Last-Modified><Content-Length>0</Content-Length>"
                "</Properties></Blob>"
            )
        if target.is_dir():
            for child in sorted(target.iterdir(), key=lambda item: item.name):
                name = prefix + child.name
                if child.is_dir():
                    prefixes.append(f"<BlobPrefix><Name>{html.escape(name)}/</Name></BlobPrefix>")
                else:
                    blobs.append(
                        f"<Blob><Name>{html.escape(name)}</Name><Properties>"
                        f"<Last-Modified>{MODIFIED_HTTP}</Last-Modified>"
                        f"<Content-Length>{child.stat().st_size}</Content-Length>"
                        "</Properties></Blob>"
                    )
        return (
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            "<EnumerationResults><Blobs>"
            + "".join(blobs)
            + "".join(prefixes)
            + "</Blobs><NextMarker /></EnumerationResults>"
        ).encode()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--port-file", required=True, type=Path)
    parser.add_argument("--cert", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args()

    args.root.mkdir(parents=True, exist_ok=True)
    (args.root / "s3" / "e2e-bucket").mkdir(parents=True, exist_ok=True)
    (args.root / "azure").mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), ObjectStorageHandler)
    server.fixture_root = args.root  # type: ignore[attr-defined]
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    args.port_file.write_text(str(server.server_port), encoding="utf-8")
    server.serve_forever()


if __name__ == "__main__":
    main()
