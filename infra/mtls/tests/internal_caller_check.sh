#!/usr/bin/env bash
# Проверка внутренней аутентификации без статических токенов на настоящем коде chat-svc, graph-rag-svc,
# auth-svc и embedding-svc: заголовку X-Caller-Identity верят только от loopback, в режиме mtls
# по умолчанию, а insecure требует явного включения. Стек не затрагивается: одноразовые контейнеры
# с кодом сервисов, смонтированным только на чтение. Код возврата — число провалов.
#
#   infra/mtls/tests/internal_caller_check.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SVC="$REPO/services"

pass=0; fail=0
run() { # образ, сервис, режим ('' = не задан), скрипт
  local env=(); [ -n "$3" ] && env=(-e "INTERNAL_AUTH_MODE=$3")
  docker run --rm -i "${env[@]}" -e PYTHONDONTWRITEBYTECODE=1 -v "$SVC/$2/app:/app/app:ro" -w /app "$1" python - <<<"$4"
}
expect() { # описание, ожидаемый вывод, фактический вывод
  if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  $1: ожидалось '$2', получено '$3'"; fi
}

# chat-svc и graph-rag-svc: один и тот же модуль app.core.internal_auth
FASTAPI_PROBE='
from app.core import internal_auth as m
h = {"X-Caller-Identity": "chat-svc"}
print(m.caller_identity(h, "127.0.0.1"), m.caller_identity(h, "::1"), m.caller_identity(h, "172.18.0.5"),
      m.caller_identity({}, "127.0.0.1"), m.caller_identity(h, None), end=" ")
try:
    m.validate_internal_auth_mode(); print("ok")
except RuntimeError as e: print("error")
'
for pair in "main-chat-svc chat-svc" "main-graph-rag-svc graph-rag-svc"; do
  set -- $pair
  expect "$2: mtls по умолчанию — только loopback и только с заголовком" \
         "chat-svc chat-svc None None None ok" "$(run "$1" "$2" "" "$FASTAPI_PROBE" 2>&1 | tr -d '\r')"
  expect "$2: insecure пускает чужой адрес, пустому заголовку даёт «unauthenticated»" \
         "chat-svc chat-svc chat-svc unauthenticated chat-svc ok" "$(run "$1" "$2" insecure "$FASTAPI_PROBE" 2>/dev/null | tr -d '\r')"
  expect "$2: неизвестный режим не стартует" "error" "$(run "$1" "$2" typo 'from app.core import internal_auth as m
try:
    m.validate_internal_auth_mode(); print("ok")
except RuntimeError: print("error")')"
done

# HTTP-зависимость graph-rag-svc и WebSocket chat-svc
expect "graph-rag-svc: чужой адрес — 403" "403" "$(run main-graph-rag-svc graph-rag-svc "" 'from app.core.internal_auth import verify_internal_http
from fastapi import HTTPException
try: verify_internal_http({"X-Caller-Identity": "chat-svc"}, "10.0.0.9")
except HTTPException as e: print(e.status_code)')"
expect "graph-rag-svc: loopback с заголовком — имя" "chat-svc" "$(run main-graph-rag-svc graph-rag-svc "" 'from app.core.internal_auth import verify_internal_http
print(verify_internal_http({"X-Caller-Identity": "chat-svc"}, "127.0.0.1"))')"

# auth-svc
AUTH_PROBE='
import asyncio
from types import SimpleNamespace as NS
from fastapi import HTTPException
from app.security import verify_internal_service_request as v
def req(host, hdr): return NS(headers=hdr, client=NS(host=host) if host else None)
async def go(host, hdr):
    try: return await v(req(host, hdr))
    except HTTPException as e: return e.status_code
h = {"X-Caller-Identity": "chat-svc"}
async def main():
    print(await go("127.0.0.1", h), await go("172.18.0.5", h), await go("127.0.0.1", {}), await go(None, h))
asyncio.run(main())
'
AUTH_IMG=main-auth-svc
expect "auth-svc: mtls — loopback с заголовком, иначе 403" "chat-svc 403 403 403" "$(run $AUTH_IMG auth-svc "" "$AUTH_PROBE" 2>/dev/null)"
expect "auth-svc: insecure" "chat-svc chat-svc unauthenticated chat-svc" "$(run $AUTH_IMG auth-svc insecure "$AUTH_PROBE" 2>/dev/null)"

# embedding-svc: настоящий main.py, тяжёлые библиотеки подменены (модель не грузится)
EMB_PROBE='
import sys, types
from unittest.mock import MagicMock
sys.modules["torch"] = MagicMock()
st = types.ModuleType("sentence_transformers"); st.SentenceTransformer = object; sys.modules["sentence_transformers"] = st
from types import SimpleNamespace as NS
from fastapi import HTTPException
import app.main as m
def req(host, hdr): return NS(headers=hdr, client=NS(host=host))
def go(host, hdr):
    try: return m.verify_internal_request(req(host, hdr))
    except HTTPException as e: return e.status_code
h = {"X-Caller-Identity": "ingest-worker"}
print(go("127.0.0.1", h), go("10.1.1.1", h), go("127.0.0.1", {}))
'
emb() { docker run --rm -i ${1:+-e INTERNAL_AUTH_MODE=$1} -e PYTHONDONTWRITEBYTECODE=1 -v "$SVC/embedding-svc/app:/emb/app:ro" -w /emb python:3.12-slim \
          sh -c 'pip install -q fastapi pydantic 2>/dev/null >/dev/null; python -' <<<"$EMB_PROBE" 2>/dev/null; }
expect "embedding-svc: mtls" "ingest-worker 403 403" "$(emb "")"
expect "embedding-svc: insecure" "ingest-worker ingest-worker unauthenticated" "$(emb insecure)"

echo
echo "Итого: $pass проверок пройдено, $fail провалено"
exit "$fail"
