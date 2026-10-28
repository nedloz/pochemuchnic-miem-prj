"""Заглушка embedding-svc для сквозной проверки (test_notebook_pipeline_flow.py).

GET /ping  -> {"status": "ok", "model": "stub-e5", "dimension": 768}
POST /embed {"texts", "normalize", "kind"} -> {"embeddings", "dimension", "model"}, как у
настоящего services/embedding-svc/app/main.py; векторы — flow_vectors.embed (kind на вектор не
влияет: префиксы e5 здесь не моделируются). Каждый запрос /embed пишется строкой JSON в
/tmp/embed_requests.jsonl (kind, длины текстов) — тест проверяет, что вопросы приходят с kind=query.
"""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import flow_vectors

LOG = "/tmp/embed_requests.jsonl"


class Handler(BaseHTTPRequestHandler):
    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/ping":
            self._send(200, {"status": "ok", "model": flow_vectors.MODEL, "dimension": flow_vectors.DIM})
        else:
            self._send(404, {"detail": "not found"})

    def do_POST(self):
        if self.path != "/embed":
            self._send(404, {"detail": "not found"})
            return
        data = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        texts = data.get("texts") or []
        kind = data.get("kind", "passage")
        if kind not in ("passage", "query"):
            self._send(422, {"detail": f"kind={kind!r}"})
            return
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({"kind": kind, "lengths": [len(t) for t in texts]}, ensure_ascii=False) + "\n")
        self._send(200, {
            "embeddings": [flow_vectors.embed(t) for t in texts],
            "dimension": flow_vectors.DIM,
            "model": flow_vectors.MODEL,
        })

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
