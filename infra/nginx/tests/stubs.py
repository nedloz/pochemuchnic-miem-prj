"""Заглушки сервисов для infra/nginx/tests/user_context_e2e.sh.

STUB=auth   — как auth-svc: /auth/validate и /auth/validate-admin выдают подписанный контекст
              настоящим модулем user_context (тем же, что в сервисах);
STUB=echo   — как получатель (chat-svc, library-svc, db-svc): возвращает присланные заголовки и
              результат проверки X-User-Context настоящим модулем.
"""

from __future__ import annotations

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, "/srv")
import user_context  # noqa: E402

KIND = os.environ["STUB"]
USERS = {
    "user-token": ("11111111-1111-1111-1111-111111111111", "student"),
    "admin-token": ("22222222-2222-2222-2222-222222222222", "admin"),
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):  # тише в логах
        pass

    def _reply(self, status: int, body: dict, headers: dict | None = None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._handle()

    do_POST = do_GET

    def _handle(self):
        parsed = urlparse(self.path)
        if KIND == "auth":
            self._auth(parsed)
        else:
            self._echo()

    # --- auth-svc ---
    def _auth(self, parsed):
        aud = parse_qs(parsed.query).get("aud", [""])[0]
        master = user_context.load_keys("/run/secrets/master")
        if parsed.path == "/auth/validate":
            bearer = (self.headers.get("Authorization") or "").removeprefix("Bearer ").strip()
            if bearer not in USERS:
                return self._reply(401, {"detail": "no"})
            uid, role = USERS[bearer]
            # Заглушка нарочно отдаёт и старые заголовки: nginx не должен их пробросить.
            return self._reply(
                200, {"status": "valid"},
                {user_context.HEADER: user_context.sign(master, aud, uid, role), "X-User-Id": uid, "X-User-Role": role},
            )
        if parsed.path == "/auth/validate-admin":
            if "admin_session=ok" not in (self.headers.get("Cookie") or ""):
                return self._reply(403, {"detail": "no"})
            uid, role = USERS["admin-token"]
            return self._reply(200, {"status": "valid"}, {user_context.HEADER: user_context.sign(master, aud, uid, role)})
        # публичные маршруты auth-svc (логин и т. п.): показываем, что до них дошло
        return self._reply(200, {"path": parsed.path, "headers": {k.lower(): v for k, v in self.headers.items()}})

    # --- получатель ---
    def _echo(self):
        headers = {k.lower(): v for k, v in self.headers.items()}
        try:
            ctx = user_context.verify_from_env(self.headers.get(user_context.HEADER))
            verified = {"user_id": ctx.user_id, "role": ctx.role, "aud": ctx.audience}
        except user_context.UserContextError as exc:
            verified = {"error": str(exc)}
        self._reply(200, {"service": os.environ["USER_CONTEXT_AUDIENCE"], "headers": headers, "verified": verified})


ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
