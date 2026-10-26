"""Клиент для infra/mtls/tests/gateway_e2e.sh: проверяет политику прокси перед auth-svc, chat-svc,
library-svc и db-svc для каждой пары «кто — куда — что», а также что обойти прокси нельзя.
Запускается в образе chat-svc (там есть websockets).

Каталоги сертификатов: /certs/<идентичность>/{tls.crt,tls.key}, корень — /certs/root_ca.crt.
"""

from __future__ import annotations

import asyncio
import http.client
import json
import socket
import ssl
import sys

import websockets

CERTS = "/certs"
ROOT = f"{CERTS}/root_ca.crt"
UUID = "11111111-1111-1111-1111-111111111111"
failures = 0


def check(cond: bool, message: str) -> None:
    global failures
    if not cond:
        failures += 1
        print(f"ПРОВАЛ  {message}")


def ctx_for(identity: str | None, root: str = ROOT) -> ssl.SSLContext:
    ctx = ssl.create_default_context(cafile=root)
    if identity:
        ctx.load_cert_chain(f"{CERTS}/{identity}/tls.crt", f"{CERTS}/{identity}/tls.key")
    return ctx


def call(host: str, identity: str | None, method: str, path: str, root: str = ROOT):
    try:
        conn = http.client.HTTPSConnection(host, 8443, context=ctx_for(identity, root), timeout=8)
        conn.request(method, path, body=b"{}" if method in ("POST", "PATCH") else None,
                     headers={"Content-Type": "application/json", "X-Caller-Identity": "forged-by-client"})
        status = conn.getresponse().status
        conn.close()
        return status
    except (ssl.SSLError, OSError, http.client.HTTPException) as exc:
        return type(exc).__name__


def caller_seen(host: str, identity: str, path: str):
    conn = http.client.HTTPSConnection(host, 8443, context=ctx_for(identity), timeout=8)
    conn.request("GET", path)
    data = json.loads(conn.getresponse().read() or b"{}")
    conn.close()
    return data.get("caller")


async def ws_open(host: str, identity: str, path: str, root: str = ROOT):
    """'connected:<кто>' при успехе, иначе код отказа или имя ошибки."""
    try:
        async with websockets.connect(f"wss://{host}:8443{path}", ssl=ctx_for(identity, root), open_timeout=8) as ws:
            first = json.loads(await asyncio.wait_for(ws.recv(), 6))
            return f"connected:{first.get('caller')}"
    except websockets.exceptions.InvalidStatus as exc:
        return exc.response.status_code
    except Exception as exc:
        return type(exc).__name__


A, C, L, D = "auth-svc", "chat-svc", "library-svc", "db-svc"
PROFILE = f"/internal/users/{UUID}/profile"

matrix = [
    # --- auth-svc: шлюзу публичное, но не внутреннее; chat-svc — только профиль ---
    # 401, а не 403: запрос дошёл до приложения (заглушка без токена отвечает 401), политика пропустила
    (A, "nginx", "GET", "/auth/validate?aud=chat-svc", 401),
    (A, "nginx", "POST", "/auth/login", 200),
    (A, "nginx", "POST", "/auth/admin-session", 200),
    (A, "nginx", "GET", "/users/me", 200),
    (A, "nginx", "PATCH", "/users/me", 200),
    (A, "nginx", "GET", PROFILE, 403),
    (A, "nginx", "GET", "/auth/../internal/users/%s/profile" % UUID, 403),
    (A, "nginx", "GET", "/docs", 403),
    (A, "nginx", "GET", "/openapi.json", 403),
    (A, "chat-svc", "GET", PROFILE, 200),
    (A, "chat-svc", "POST", "/auth/login", 403),
    (A, "chat-svc", "GET", "/auth/validate?aud=chat-svc", 403),
    (A, "chat-svc", "GET", "/users/me", 403),
    (A, "db-svc", "GET", PROFILE, 403),
    (A, "graph-rag-svc", "GET", PROFILE, 403),
    (A, "library-svc", "GET", "/auth/validate", 403),
    # --- library-svc: только шлюз и только его пути ---
    (L, "nginx", "GET", "/library/tree", 200),
    (L, "nginx", "POST", "/library/refresh", 200),
    (L, "nginx", "GET", "/api/documents/abc/download", 200),
    (L, "nginx", "GET", "/admin", 403),
    (L, "chat-svc", "GET", "/library/tree", 403),
    (L, "db-svc", "GET", "/library/tree", 403),
    (L, "auth-svc", "GET", "/library/tree", 403),
    # --- db-svc: только шлюз ---
    (D, "nginx", "GET", "/api/db/schemas", 200),
    (D, "nginx", "POST", "/api/db/import/csv", 200),
    (D, "chat-svc", "GET", "/api/db/schemas", 403),
    (D, "graph-rag-svc", "GET", "/", 403),
    (D, "auth-svc", "GET", "/", 403),
    # --- chat-svc: WebSocket шлюза и внутренний WebSocket graph-rag-svc ---
    (C, "nginx", "GET", "/ws/chat", 200),
    (C, "nginx", "GET", "/ws/internal/llm", 403),
    (C, "nginx", "GET", "/healthz", 403),
    (C, "graph-rag-svc", "GET", "/ws/internal/llm", 200),
    (C, "graph-rag-svc", "GET", "/ws/chat", 403),
    (C, "db-svc", "GET", "/ws/chat", 403),
    (C, "auth-svc", "GET", "/ws/internal/llm", 403),
]
for host, who, method, path, expected in matrix:
    got = call(host, who, method, path)
    check(got == expected, f"{who} → {host} {method} {path}: ожидалось {expected}, получено {got}")

# идентичность задаёт только сертификат
check(caller_seen(A, "nginx", "/auth/login") == "nginx", "auth-svc: проверенная идентичность nginx не проставлена")
check(caller_seen(A, "chat-svc", PROFILE) == "chat-svc", "auth-svc: клиентский X-Caller-Identity не заменён")

# --- без сертификата, с чужим, мимо прокси --------------------------------------------------------------------
for host in (A, C, L, D):
    check(call(host, None, "GET", "/") != 200, f"{host}: без сертификата получен 200")
    check(call(host, "rogue", "GET", "/") != 200, f"{host}: самоподписанный «nginx» принят")
    try:
        socket.create_connection((host, 8000), timeout=3).close()
        check(False, f"{host}:8000 доступен напрямую в обход прокси")
    except OSError:
        pass
    try:
        conn = http.client.HTTPConnection(host, 8443, timeout=5)
        conn.request("GET", "/")
        check(conn.getresponse().status != 200, f"{host}: открытый HTTP на порту mTLS получил 200")
    except (OSError, http.client.HTTPException):
        pass


async def websockets_checks():
    r = await ws_open(C, "nginx", "/ws/chat")
    check(r == "connected:nginx", f"WebSocket шлюза в chat-svc: {r}")
    r = await ws_open(C, "graph-rag-svc", "/ws/internal/llm")
    check(r == "connected:graph-rag-svc", f"внутренний WebSocket graph-rag-svc в chat-svc: {r}")
    r = await ws_open(C, "graph-rag-svc", "/ws/chat")
    check(r == 403, f"graph-rag-svc в пользовательский WebSocket: ожидался 403, получено {r}")
    r = await ws_open(C, "chat-svc", "/ws/chat")
    check(r == 403, f"chat-svc сам к себе в пользовательский WebSocket: ожидался 403, получено {r}")
    r = await ws_open(C, "rogue", "/ws/chat")
    check(isinstance(r, str) or r != "connected:nginx", f"WebSocket с самоподписанным сертификатом принят: {r}")


asyncio.run(websockets_checks())

print(f"Провалов: {failures}")
sys.exit(1 if failures else 0)
