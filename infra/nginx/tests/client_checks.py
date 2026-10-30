"""Клиентская часть infra/nginx/tests/user_context_e2e.sh: ходит в nginx как браузер или как
злоумышленник из соседнего контейнера и проверяет, что именно дошло до сервисов."""

from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request

sys.path.insert(0, "/srv")
import user_context  # noqa: E402

BASE = "http://nginx"
USER = "11111111-1111-1111-1111-111111111111"
ADMIN = "22222222-2222-2222-2222-222222222222"
failures = 0


def req(path: str, headers: dict | None = None, method: str = "GET"):
    r = urllib.request.Request(BASE + path, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(r, timeout=10) as resp:
            body = resp.read()
            return resp.status, (json.loads(body) if body else {})
    except urllib.error.HTTPError as exc:
        body = exc.read()
        try:
            return exc.code, json.loads(body)
        except ValueError:
            return exc.code, {}


def check(cond: bool, message: str) -> None:
    global failures
    if not cond:
        failures += 1
        print(f"ПРОВАЛ  {message}")


# Подделка: токен, подписанный не тем ключом, и голые заголовки «я другой пользователь».
forged_key = [bytes([7]) * 32]
forged = user_context.sign(forged_key, "library-svc", ADMIN, "admin")
FORGED_HEADERS = {
    "X-User-Id": ADMIN,
    "X-User-Role": "admin",
    user_context.HEADER: forged,
}

# --- библиотека: обычный пользователь ---------------------------------------------------------
st, body = req("/api/library/tree", {"Authorization": "Bearer user-token"})
check(st == 200, f"library: ожидался 200, получен {st}")
check(body.get("verified") == {"user_id": USER, "role": "student", "aud": "library-svc"},
      f"library: контекст не проверился: {body.get('verified')}")
check("x-user-id" not in body.get("headers", {}) and "x-user-role" not in body.get("headers", {}),
      "library: до сервиса дошли голые X-User-Id / X-User-Role")

# --- те же запросы с подделкой: nginx должен подменить подделку настоящим контекстом -------------
st, body = req("/api/library/tree", {"Authorization": "Bearer user-token", **FORGED_HEADERS})
check(st == 200 and body.get("verified", {}).get("user_id") == USER and body["verified"]["role"] == "student",
      f"library: подделанные заголовки клиента повлияли на результат: {body.get('verified')}")
check("x-user-id" not in body.get("headers", {}), "library: клиентский X-User-Id дошёл до сервиса")

# --- без токена доступа нет -----------------------------------------------------------------------
st, _ = req("/api/library/tree", FORGED_HEADERS)
check(st == 401, f"library без токена, но с поддельными заголовками: ожидался 401, получен {st}")

# --- документы идут тоже в library-svc ---------------------------------------------------------------
st, body = req("/api/documents/x", {"Authorization": "Bearer user-token"})
check(st == 200 and body.get("verified", {}).get("aud") == "library-svc", f"documents: {st} {body.get('verified')}")

# --- WebSocket-маршрут: токен в query, аудитория chat-svc --------------------------------------------
st, body = req("/api/chat/ws/chat?token=user-token")
check(st == 200 and body.get("verified") == {"user_id": USER, "role": "student", "aud": "chat-svc"},
      f"chat: {st} {body.get('verified')}")
st, _ = req("/api/chat/ws/chat?token=wrong")
check(st == 401, f"chat с неверным токеном: ожидался 401, получен {st}")

# --- профиль (auth-svc как получатель) ---------------------------------------------------------------------
st, body = req("/api/users/me", {"Authorization": "Bearer user-token", **FORGED_HEADERS})
check(st == 200, f"users/me: {st}")
ctx = body.get("headers", {}).get(user_context.HEADER.lower())
check(ctx is not None and ctx != forged, "users/me: клиентский X-User-Context не заменён")
if ctx:
    master_derived = None  # проверка ключом auth-svc выполняется в самих сервисах; здесь — формат
    check(ctx.count(".") == 2, "users/me: контекст не в формате JWT")

# --- публичные маршруты: присланное клиентом не доходит до auth-svc -----------------------------------------
st, body = req("/api/auth/login", FORGED_HEADERS, method="POST")
hdrs = body.get("headers", {})
check(st == 200, f"login: {st}")
check(user_context.HEADER.lower() not in hdrs and "x-user-id" not in hdrs and "x-user-role" not in hdrs,
      f"login: клиентские заголовки контекста дошли до auth-svc: {sorted(h for h in hdrs if h.startswith('x-user'))}")

st, body = req("/api/auth/resend-verification", FORGED_HEADERS, method="POST")
check(st == 200 and body.get("path") == "/auth/resend-verification",
      f"resend-verification должен доходить до auth-svc без access-токена: {st} {body}")
hdrs = body.get("headers", {})
check(user_context.HEADER.lower() not in hdrs and "x-user-id" not in hdrs and "x-user-role" not in hdrs,
      "resend-verification: клиентские заголовки контекста дошли до auth-svc")

# --- админка ---------------------------------------------------------------------------------------------------------
st, _ = req("/admin/", {"X-User-Role": "admin", "X-User-Id": ADMIN})
check(st == 404, f"админка без сессии, но с «ролью» в заголовке: ожидался 404, получен {st}")
st, body = req("/admin/", {"Cookie": "admin_session=ok", **FORGED_HEADERS})
check(st == 200 and body.get("verified") == {"user_id": ADMIN, "role": "admin", "aud": "db-svc"},
      f"админка с сессией: {st} {body.get('verified')}")
check("x-user-role" not in body.get("headers", {}), "админка: до db-svc дошёл голый X-User-Role")

print(f"Провалов: {failures}")
sys.exit(1 if failures else 0)
