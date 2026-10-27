"""Клиент для metrics_policy.sh: проверяет политику прокси для /metrics.

Каталоги сертификатов: /certs/<имя> (tls.crt, tls.key, root_ca.crt).
"""

from __future__ import annotations

import http.client
import ssl
import sys

CERTS = "/certs"
SERVICES = ["auth-svc", "chat-svc", "library-svc", "db-svc", "graph-rag-svc", "embedding-svc"]
failures = 0


def call(host: str, identity: str, path: str) -> int | str:
    ctx = ssl.create_default_context(cafile=f"{CERTS}/root_ca.crt")
    ctx.load_cert_chain(f"{CERTS}/{identity}/tls.crt", f"{CERTS}/{identity}/tls.key")
    try:
        conn = http.client.HTTPSConnection(host, 8443, context=ctx, timeout=8)
        conn.request("GET", path)
        return conn.getresponse().status
    except Exception as exc:  # рукопожатие отвергнуто и т. п.
        return f"{type(exc).__name__}"


def check(cond: bool, message: str) -> None:
    global failures
    if not cond:
        failures += 1
        print(f"ПРОВАЛ  {message}")


for svc in SERVICES:
    got = call(svc, "prometheus", "/metrics")
    check(got == 200, f"{svc}: prometheus GET /metrics -> 200, получено {got}")
    for other in ("/", "/healthz", "/metrics/extra", "/metricsx"):
        got = call(svc, "prometheus", other)
        check(got == 403, f"{svc}: prometheus GET {other} -> 403, получено {got}")
    got = call(svc, "nginx", "/metrics")
    check(got == 403, f"{svc}: nginx GET /metrics -> 403, получено {got}")
    got = call(svc, "chat-svc", "/metrics")
    check(got == 403, f"{svc}: chat-svc GET /metrics -> 403, получено {got}")

print(f"Провалов: {failures}")
sys.exit(1 if failures else 0)
