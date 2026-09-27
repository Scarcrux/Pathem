#!/usr/bin/env python3
"""Small loopback-only FTP fixture for Pathem's real curl provider.

It implements only the commands the environmental CRUD probe uses. The server binds
127.0.0.1 on an ephemeral port and confines every path to a disposable root.
"""

from __future__ import annotations

import argparse
import os
import socket
import socketserver
from pathlib import Path


class FTPHandler(socketserver.StreamRequestHandler):
    root: Path
    passive: socket.socket | None = None
    rename_from: Path | None = None

    def reply(self, code: int, message: str) -> None:
        self.wfile.write(f"{code} {message}\r\n".encode())
        self.wfile.flush()

    def resolved(self, raw: str) -> Path:
        relative = raw.strip().lstrip("/")
        candidate = (self.root / relative).resolve()
        if candidate != self.root and self.root not in candidate.parents:
            raise ValueError("path escaped fixture root")
        return candidate

    def data_connection(self) -> socket.socket:
        if self.passive is None:
            raise RuntimeError("passive mode not established")
        connection, _ = self.passive.accept()
        self.passive.close()
        self.passive = None
        return connection

    def handle(self) -> None:
        self.root = Path(self.server.root).resolve()  # type: ignore[attr-defined]
        self.reply(220, "Pathem loopback FTP fixture")
        while raw := self.rfile.readline():
            line = raw.decode("utf-8", "replace").rstrip("\r\n")
            command, _, argument = line.partition(" ")
            command = command.upper()
            try:
                if command == "USER":
                    self.reply(331, "Password required")
                elif command == "PASS":
                    self.reply(230, "Logged in")
                elif command in {"SYST", "TYPE", "OPTS", "NOOP"}:
                    self.reply(200 if command != "SYST" else 215, "UNIX Type: L8")
                elif command == "FEAT":
                    self.wfile.write(b"211-Features\r\n EPSV\r\n UTF8\r\n211 End\r\n")
                    self.wfile.flush()
                elif command == "PWD":
                    self.reply(257, '"/" is current directory')
                elif command == "CWD":
                    self.reply(250, "Directory changed")
                elif command in {"EPSV", "PASV"}:
                    if self.passive is not None:
                        self.passive.close()
                    self.passive = socket.socket()
                    self.passive.bind(("127.0.0.1", 0))
                    self.passive.listen(1)
                    port = self.passive.getsockname()[1]
                    if command == "EPSV":
                        self.reply(229, f"Entering Extended Passive Mode (|||{port}|)")
                    else:
                        self.reply(227, f"Entering Passive Mode (127,0,0,1,{port // 256},{port % 256})")
                elif command == "LIST":
                    self.reply(150, "Opening data connection")
                    with self.data_connection() as data:
                        for item in sorted(self.root.iterdir()):
                            kind = "d" if item.is_dir() else "-"
                            size = item.stat().st_size
                            data.sendall(
                                f"{kind}rw-r--r-- 1 owner group {size} Jan 01 00:00 {item.name}\r\n".encode()
                            )
                    self.reply(226, "Transfer complete")
                elif command == "STOR":
                    target = self.resolved(argument)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    self.reply(150, "Opening data connection")
                    with self.data_connection() as data, target.open("wb") as output:
                        while chunk := data.recv(65536):
                            output.write(chunk)
                    self.reply(226, "Transfer complete")
                elif command == "RETR":
                    target = self.resolved(argument)
                    self.reply(150, "Opening data connection")
                    with self.data_connection() as data, target.open("rb") as source:
                        while chunk := source.read(65536):
                            data.sendall(chunk)
                    self.reply(226, "Transfer complete")
                elif command == "MKD":
                    self.resolved(argument).mkdir(parents=False)
                    self.reply(257, "Directory created")
                elif command == "RMD":
                    self.resolved(argument).rmdir()
                    self.reply(250, "Directory removed")
                elif command == "DELE":
                    self.resolved(argument).unlink()
                    self.reply(250, "File removed")
                elif command == "RNFR":
                    self.rename_from = self.resolved(argument)
                    self.reply(350, "Ready for destination")
                elif command == "RNTO":
                    if self.rename_from is None:
                        self.reply(503, "RNFR required")
                    else:
                        self.rename_from.rename(self.resolved(argument))
                        self.rename_from = None
                        self.reply(250, "Rename complete")
                elif command == "SIZE":
                    self.reply(213, str(self.resolved(argument).stat().st_size))
                elif command == "QUIT":
                    self.reply(221, "Goodbye")
                    return
                else:
                    self.reply(502, f"Unsupported command {command}")
            except (OSError, RuntimeError, ValueError) as error:
                self.reply(550, str(error))

    def finish(self) -> None:
        if self.passive is not None:
            self.passive.close()
        super().finish()


class ThreadedFTPServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()
    root = Path(args.root)
    root.mkdir(parents=True, exist_ok=True)
    with ThreadedFTPServer(("127.0.0.1", 0), FTPHandler) as server:
        server.root = str(root)  # type: ignore[attr-defined]
        Path(args.port_file).write_text(str(server.server_address[1]))
        server.serve_forever()


if __name__ == "__main__":
    main()
