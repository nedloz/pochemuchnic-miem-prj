"""Проверки реального кода сервисов-получателей: запускается внутри образа сервиса с его кодом
(infra/nginx/tests/user_context_e2e.sh).

    python service_checks.py <auth-svc|chat-svc|library-svc|db-svc>

Каждый сервис принимает контекст, выписанный ему, и отвергает: токен для другого сервиса,
просроченный, подписанный чужим ключом, отсутствие токена и (без USER_CONTEXT_ALLOW_LEGACY)
голые X-User-Id / X-User-Role.
"""

from __future__ import annotations

import asyncio
import os
import sys
import time
import uuid

sys.path.insert(0, os.getcwd())
from app import user_context  # noqa: E402

SERVICE = sys.argv[1]
USER = "11111111-1111-1111-1111-111111111111"
ADMIN = "22222222-2222-2222-2222-222222222222"
failures = 0


def check(cond: bool, message: str) -> None:
    global failures
    if not cond:
        failures += 1
        print(f"ПРОВАЛ  [{SERVICE}] {message}")


master = user_context.load_keys("/run/secrets/master")
other_master = [bytes([9]) * 32]


def token(aud: str = SERVICE, uid: str = USER, role: str = "student", keys=None, issued: float | None = None, ttl: int = 60) -> str:
    return user_context.sign(keys or master, aud, uid, role, ttl_sec=ttl, now=issued)


# --- общий слой: сам модуль -----------------------------------------------------------------------------------
own_keys = user_context.load_keys(os.environ["USER_CONTEXT_KEY_FILE"])
ctx = user_context.verify(token(), SERVICE, own_keys)
check(ctx.user_id == USER and ctx.role == "student", "модуль не принял собственный токен")
for name, bad in {
    "токен для другого сервиса": token(aud="other-svc"),
    "чужая подпись": token(keys=other_master),
    "просроченный": token(issued=time.time() - 3600),
    "выдан в будущем": token(issued=time.time() + 3600),
    "пустой": "",
    "мусор": "abc.def.ghi",
    "без подписи (alg=none)": ".".join([
        "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0",
        token().split(".")[1],
        "",
    ]),
}.items():
    try:
        user_context.verify(bad, SERVICE, own_keys)
        check(False, f"модуль принял: {name}")
    except user_context.UserContextError:
        pass
# производный ключ другого сервиса не подходит: компрометация одного получателя не даёт подделать другого
try:
    user_context.verify(
        user_context.sign([user_context.derive_key(master[0], "other-svc")], SERVICE, USER, "student"),
        SERVICE, own_keys,
    )
    check(False, "ключ другого получателя подошёл")
except user_context.UserContextError:
    pass


def rejects(call) -> bool:
    try:
        call()
    except Exception:
        return True
    return False


# --- реальный код сервиса -------------------------------------------------------------------------------------------
if SERVICE == "library-svc":
    from app.auth import get_gateway_user_id

    ok = get_gateway_user_id(x_user_context=token(), x_user_id=None)
    check(ok == uuid.UUID(USER), "library: свой токен не принят")
    check(rejects(lambda: get_gateway_user_id(x_user_context=token(aud="chat-svc"), x_user_id=None)), "library: принят токен для chat-svc")
    check(rejects(lambda: get_gateway_user_id(x_user_context=token(keys=other_master), x_user_id=None)), "library: принята чужая подпись")
    check(rejects(lambda: get_gateway_user_id(x_user_context=None, x_user_id=USER)), "library: принят голый X-User-Id")
    os.environ["USER_CONTEXT_ALLOW_LEGACY"] = "true"
    check(get_gateway_user_id(x_user_context=None, x_user_id=USER) == uuid.UUID(USER), "library: переходный режим не работает")
    check(rejects(lambda: get_gateway_user_id(x_user_context=token(keys=other_master), x_user_id=USER)),
          "library: в переходном режиме подделанный токен «спасён» голым заголовком")

elif SERVICE == "chat-svc":
    from app.ws.handler import ChatWebSocketHandler as ChatHandler

    from starlette.datastructures import Headers

    class WS:
        def __init__(self, headers):
            # как у настоящего WebSocket: имена заголовков без учёта регистра
            self.headers = Headers(headers)

    extract = ChatHandler._extract_user_id
    check(extract(None, WS({user_context.HEADER.lower(): token()}), None) == uuid.UUID(USER), "chat: свой токен не принят")
    check(rejects(lambda: extract(None, WS({user_context.HEADER.lower(): token(aud="library-svc")}), None)), "chat: принят токен для library-svc")
    check(rejects(lambda: extract(None, WS({user_context.HEADER.lower(): token(keys=other_master)}), None)), "chat: принята чужая подпись")
    check(rejects(lambda: extract(None, WS({"x-user-id": USER}), None)), "chat: принят голый X-User-Id")
    os.environ["USER_CONTEXT_ALLOW_LEGACY"] = "true"
    check(extract(None, WS({"x-user-id": USER}), None) == uuid.UUID(USER), "chat: переходный режим не работает")

elif SERVICE == "auth-svc":
    from app.security import _user_id_from_headers as extract

    check(extract(token(), None) == USER, "auth: свой токен не принят")
    check(rejects(lambda: extract(token(aud="chat-svc"), None)), "auth: принят токен для chat-svc")
    check(rejects(lambda: extract(token(keys=other_master), None)), "auth: принята чужая подпись")
    check(rejects(lambda: extract(None, USER)), "auth: принят голый X-User-Id")
    os.environ["USER_CONTEXT_ALLOW_LEGACY"] = "true"
    check(extract(None, USER) == USER, "auth: переходный режим не работает")

    # выдача контекста (то, что nginx получает от /auth/validate)
    from app.routers.auth import _issue_user_context
    from fastapi import HTTPException

    class U:
        id = USER
        role = "student"

    os.environ["USER_CONTEXT_MASTER_FILE"] = "/run/secrets/master"
    issued = _issue_user_context(U(), "chat-svc")
    check(user_context.verify(issued, "chat-svc",
                              user_context.load_keys("/run/secrets/chat-svc.key")).user_id == USER,
          "auth: выданный контекст не проверяется ключом chat-svc")
    check(rejects(lambda: _issue_user_context(U(), "evil-svc")), "auth: выдан контекст для неизвестного сервиса")
    del os.environ["USER_CONTEXT_MASTER_FILE"]
    try:
        _issue_user_context(U(), "chat-svc")
        check(False, "auth: выдан контекст без мастер-ключа")
    except HTTPException as exc:
        check(exc.status_code == 503, f"auth: без ключа ожидался 503, получен {exc.status_code}")

elif SERVICE == "db-svc":
    os.environ["DBSVC_ADMIN_TOKEN"] = "bearer-secret"
    from fastapi import HTTPException
    from starlette.requests import Request

    from app.core.auth import require_auth

    def request(headers: dict[str, str]) -> Request:
        return Request({
            "type": "http", "method": "GET", "path": "/api/db/schemas", "query_string": b"",
            "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()],
            "client": ("203.0.113.9", 1234),
        })

    admin = token(uid=ADMIN, role="admin")
    actor = require_auth(request({user_context.HEADER: admin, "X-Real-IP": "198.51.100.5"}))
    check(actor.kind == "user" and actor.user_id == ADMIN and actor.role == "admin", f"db: контекст админа не принят: {actor}")
    check(actor.ip == "198.51.100.5", f"db: адрес клиента за подписанным шлюзом: {actor.ip}")

    def denied(headers, code):
        try:
            require_auth(request(headers))
        except HTTPException as exc:
            return exc.status_code == code
        return False

    check(denied({user_context.HEADER: token(uid=USER, role="student")}, 403), "db: роль student получила доступ")
    check(denied({user_context.HEADER: token(uid=ADMIN, role="admin", aud="chat-svc")}, 401), "db: принят токен для chat-svc")
    check(denied({user_context.HEADER: token(uid=ADMIN, role="admin", keys=other_master)}, 401), "db: принята чужая подпись")
    check(denied({"X-User-Role": "admin", "X-User-Id": ADMIN}, 401), "db: голый X-User-Role: admin дал доступ")
    check(require_auth(request({"Authorization": "Bearer bearer-secret"})).kind == "token", "db: Bearer-токен перестал работать")
    # поддельный адрес без подписанного шлюза не принимается на веру
    check(require_auth(request({"Authorization": "Bearer bearer-secret", "X-Real-IP": "6.6.6.6"})).ip == "203.0.113.9",
          "db: X-Real-IP принят без подтверждённого шлюза")
    os.environ["USER_CONTEXT_ALLOW_LEGACY"] = "true"
    check(require_auth(request({"X-User-Role": "admin", "X-User-Id": ADMIN})).kind == "user", "db: переходный режим не работает")

print(f"[{SERVICE}] провалов: {failures}")
sys.exit(1 if failures else 0)
