"""Клиент для infra/mtls/tests/mtls_e2e.sh: ходит к прокси с разными сертификатами и проверяет
политику «кто что может вызывать», а также что обойти прокси нельзя.

    python policy_client.py <identity-dir> ...   (каталоги: /certs/<имя> с tls.crt, tls.key, root_ca.crt)
"""

from __future__ import annotations

import hashlib
import http.client
import socket
import ssl
import sys

CERTS = "/certs"
ROOT = f"{CERTS}/root_ca.crt"
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


def call(host: str, identity: str | None, method: str, path: str, root: str = ROOT) -> int | str:
    """Статус ответа или текст сетевой ошибки (рукопожатие отвергнуто)."""
    try:
        conn = http.client.HTTPSConnection(host, 8443, context=ctx_for(identity, root), timeout=8)
        conn.request(method, path, body=b"{}" if method in ("POST", "PATCH") else None,
                     headers={"Content-Type": "application/json", "X-Caller-Identity": "forged-by-client"})
        status = conn.getresponse().status
        conn.close()
        return status
    except (ssl.SSLError, OSError, http.client.HTTPException) as exc:
        return f"{type(exc).__name__}"


def body_caller(host: str, identity: str, path: str) -> str | None:
    import json
    conn = http.client.HTTPSConnection(host, 8443, context=ctx_for(identity), timeout=8)
    conn.request("GET", path)
    data = json.loads(conn.getresponse().read() or b"{}")
    conn.close()
    return data.get("caller")


def server_fingerprint(host: str, identity: str) -> str:
    raw = socket.create_connection((host, 8443), timeout=8)
    tls = ctx_for(identity).wrap_socket(raw, server_hostname=host)
    der = tls.getpeercert(binary_form=True)
    tls.close()
    return hashlib.sha256(der).hexdigest()


if len(sys.argv) > 1 and sys.argv[1] == "fingerprint":
    print(server_fingerprint(sys.argv[2], "chat-svc"))
    sys.exit(0)

G, E = "graph-rag-svc", "embedding-svc"

# --- политика graph-rag-svc ---------------------------------------------------------------------------------------
matrix = [
    # (получатель, кто, метод, путь, ожидаемый статус)
    (G, "chat-svc", "POST", "/generate", 200),
    (G, "chat-svc", "POST", "/cancel", 200),
    (G, "chat-svc", "GET", "/healthz", 200),
    (G, "chat-svc", "GET", "/internal/graph/entities", 403),
    (G, "chat-svc", "GET", "/generate/../internal/graph/entities", 403),
    (G, "chat-svc", "POST", "/embed", 403),
    (G, "db-svc", "GET", "/internal/graph/entities", 200),
    (G, "db-svc", "PATCH", "/internal/graph/entities/1", 200),
    (G, "db-svc", "DELETE", "/internal/graph/entities/1", 200),
    (G, "db-svc", "POST", "/generate", 403),
    (G, "db-svc", "POST", "/cancel", 403),
    (G, "ingest-worker", "GET", "/healthz", 403),
    (G, "ingest-worker", "POST", "/generate", 403),
    (G, "graph-rag-svc", "POST", "/generate", 403),
    # --- политика embedding-svc ---
    (E, "graph-rag-svc", "POST", "/embed", 200),
    (E, "graph-rag-svc", "GET", "/ping", 200),
    (E, "ingest-worker", "POST", "/embed", 200),
    (E, "ingest-worker", "GET", "/ping", 200),
    (E, "chat-svc", "POST", "/embed", 403),
    (E, "db-svc", "POST", "/embed", 403),
    (E, "ingest-worker", "GET", "/admin", 403),
    (E, "ingest-worker", "POST", "/embed/../metrics", 403),
]
for host, who, method, path, expected in matrix:
    got = call(host, who, method, path)
    check(got == expected, f"{who} → {host} {method} {path}: ожидалось {expected}, получено {got}")

# --- идентичность задаёт только сертификат ------------------------------------------------------------------------
check(body_caller(G, "chat-svc", "/healthz") == "chat-svc", "прокси не проставил проверенную идентичность chat-svc")
check(body_caller(E, "ingest-worker", "/ping") == "ingest-worker",
      "клиентский X-Caller-Identity не заменён проверенной идентичностью")

# --- без сертификата и с чужим --------------------------------------------------------------------------------------
for host in (G, E):
    probe = "/healthz" if host == G else "/ping"
    no_cert = call(host, None, "GET", probe)
    check(no_cert != 200, f"{host}: без клиентского сертификата получен 200")
    rogue = call(host, "rogue", "GET", probe)
    check(rogue != 200, f"{host}: самоподписанный сертификат с CN=chat-svc принят: {rogue}")

# --- обойти прокси нельзя ---------------------------------------------------------------------------------------------
for host in (G, E):
    for port in (8000,):
        try:
            socket.create_connection((host, port), timeout=3).close()
            check(False, f"{host}:{port} доступен напрямую в обход прокси")
        except OSError:
            pass
    try:  # открытый HTTP на порт mTLS
        conn = http.client.HTTPConnection(host, 8443, timeout=5)
        conn.request("GET", "/healthz")
        status = conn.getresponse().status
        check(status != 200, f"{host}: открытый HTTP на порту mTLS получил {status}")
    except (OSError, http.client.HTTPException):
        pass

# --- клиент не верит серверу без нашего CA ---------------------------------------------------------------------------------
check(isinstance(call(G, "chat-svc", "GET", "/healthz", root=f"{CERTS}/rogue/root_ca.crt"), str),
      "клиент принял сервер, не подписанный доверенным корнем")

print(f"Провалов: {failures}")
sys.exit(1 if failures else 0)
