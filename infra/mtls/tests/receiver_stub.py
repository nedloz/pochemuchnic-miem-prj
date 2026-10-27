"""Заглушка получателя для infra/mtls/tests/mtls_e2e.sh.

Слушает ТОЛЬКО 127.0.0.1:8000, как настоящее приложение после переключения на mTLS: достучаться
до неё можно лишь через прокси в том же сетевом пространстве. Отвечает JSON с тем, что дошло.
POST /embed ведёт себя как embedding-svc (векторы размерности EMBED_DIM).
"""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIM = int(os.getenv("EMBED_DIM", "8"))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _handle(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        headers = {k.lower(): v for k, v in self.headers.items()}
        if self.path == "/embed" and self.command == "POST":
            texts = json.loads(raw or b"{}").get("texts", [])
            return self._reply(200, {
                "embeddings": [[0.0] * DIM for _ in texts], "model": "stub-model", "dimension": DIM,
                "caller": headers.get("x-caller-identity"),
            })
        if self.path == "/metrics" and self.command == "GET":
            text = b"# TYPE stub_up gauge\nstub_up 1\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(text)))
            self.end_headers()
            return self.wfile.write(text)
        if self.path in ("/ping", "/health", "/healthz"):
            return self._reply(200, {"status": "ok", "caller": headers.get("x-caller-identity")})
        return self._reply(200, {
            "path": self.path, "method": self.command,
            "caller": headers.get("x-caller-identity"), "job": "stub", "status": "queued",
        })

    do_GET = do_POST = do_PATCH = do_DELETE = _handle


ThreadingHTTPServer(("127.0.0.1", 8000), Handler).serve_forever()
