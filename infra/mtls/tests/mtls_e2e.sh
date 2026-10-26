#!/usr/bin/env bash
# Проверка mTLS между сервисами: одноразовый CA, настоящие прокси с боевыми конфигами
# (infra/mtls/*.conf), заглушки получателей (слушают только localhost) и настоящий клиентский код
# сервисов (graph_rag.call из db-svc, LlmService из chat-svc, embed_texts_with_model и
# startup-проверка из graph-rag-svc, _embed из ingest-worker). Стек не затрагивается (префикс mtlst).
# Код возврата — число провалов.
#
#   infra/mtls/tests/mtls_e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
P=mtlst
export PKI_DIR="$TMP/pki" PKI_CA_CONTAINER="$P-ca" PKI_CA_VOLUME="${P}_ca_data"
source "$REPO/scripts/pki/lib.sh"
NET="$P-net"
PY=python:3.12-slim
IDS=(graph-rag-svc embedding-svc chat-svc db-svc ingest-worker)

pass=0; fail=0
check()     { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  $d"; fi; }
check_not() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail=$((fail + 1)); echo "ПРОВАЛ  $d"; else pass=$((pass + 1)); fi; }

cleanup() {
    docker rm -f "$PKI_CA_CONTAINER" "$P-graph-rag-svc" "$P-graph-rag-svc-mtls" "$P-embedding-svc" "$P-embedding-svc-mtls" >/dev/null 2>&1
    for id in "${IDS[@]}"; do docker volume rm -f "${P}_$id" >/dev/null 2>&1; done
    docker volume rm -f "$PKI_CA_VOLUME" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT
cleanup >/dev/null 2>&1; mkdir -p "$TMP"

echo "== центр сертификации и сертификаты сервисов"
"$REPO/scripts/pki/init.sh" >/dev/null 2>&1 || { echo "ПРОВАЛ  init.sh"; exit 1; }
docker network create "$NET" >/dev/null
docker run -d --name "$PKI_CA_CONTAINER" --network "$NET" --network-alias step-ca --entrypoint /bin/sh \
    -e PKI_CERT_TTL=24h -v "$PKI_CA_VOLUME:/home/step" -v "$REPO/infra/pki/entrypoint.sh:/entrypoint.sh:ro" \
    "$STEP_IMAGE" /entrypoint.sh >/dev/null
for _ in $(seq 1 30); do
    docker exec "$PKI_CA_CONTAINER" step ca health --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt >/dev/null 2>&1 && break
    sleep 1
done
for id in "${IDS[@]}"; do
    "$REPO/scripts/pki/enroll.sh" "$id" --volume "${P}_$id" >/dev/null 2>&1 || { echo "ПРОВАЛ  сертификат $id"; exit 1; }
done
ROOT="$PKI_DIR/root_ca.crt"
mkdir -p "$TMP/rogue"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$TMP/rogue/tls.key" \
    -out "$TMP/rogue/tls.crt" -subj "/CN=chat-svc" -addext "subjectAltName=DNS:chat-svc" -days 1 >/dev/null 2>&1
cp "$TMP/rogue/tls.crt" "$TMP/rogue/root_ca.crt"; chmod -R a+rX "$TMP/rogue"

echo "== получатели: заглушка на localhost + прокси с боевым конфигом"
receiver() { # имя
    docker run -d --name "$P-$1" --network "$NET" --network-alias "$1" --entrypoint "" \
        -v "$HERE/receiver_stub.py:/srv/receiver_stub.py:ro" -e EMBED_DIM=8 "$PY" python /srv/receiver_stub.py >/dev/null
    docker run -d --name "$P-$1-mtls" --network "container:$P-$1" \
        -v "${P}_$1:/pki-svc:ro" -v "$REPO/infra/mtls/$1.conf:/etc/nginx/conf.d/default.conf:ro" \
        nginx:1.27-alpine >/dev/null
}
receiver graph-rag-svc; receiver embedding-svc
sleep 3
for r in graph-rag-svc embedding-svc; do
    if ! docker exec "$P-$r-mtls" nginx -t >/dev/null 2>&1; then
        echo "ПРОВАЛ  nginx -t ($r):"; docker exec "$P-$r-mtls" nginx -t 2>&1 | tail -4; fail=$((fail + 1))
    fi
done

CERT_MOUNTS=(-v "$ROOT:/certs/root_ca.crt:ro" -v "$TMP/rogue:/certs/rogue:ro")
for id in "${IDS[@]}"; do CERT_MOUNTS+=(-v "${P}_$id:/certs/$id:ro"); done

echo "== политика и обход прокси"
out="$(docker run --rm --network "$NET" --entrypoint "" "${CERT_MOUNTS[@]}" -v "$HERE/policy_client.py:/policy_client.py:ro" \
    "$PY" python /policy_client.py 2>&1)"
rc=$?
echo "$out" | grep -v "^Провалов"
if [[ $rc -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi

echo "== настоящий клиентский код сервисов"
run_py() { # образ, каталог кода сервиса, том сертификата, код (stdin), [-e ...]
    local image=$1 code=$2 vol=$3; shift 3
    docker run --rm -i --network "$NET" --entrypoint "" -e PYTHONDONTWRITEBYTECODE=1 \
        -v "$code" -v "$vol:/pki-svc:ro" \
        -e SERVICE_MTLS_CERT=/pki-svc/tls.crt -e SERVICE_MTLS_KEY=/pki-svc/tls.key -e SERVICE_MTLS_CA=/pki-svc/root_ca.crt \
        "$@" "$image" python - 2>&1
}
res() { grep -o 'RESULT.*' <<<"$1" | head -1; }

out="$(run_py main-db-svc "$REPO/services/db-svc/app:/app/app:ro" "${P}_db-svc" -w /app -e GRAPH_RAG_URL=https://graph-rag-svc:8443 <<'PYEND'
from app.services.graph_rag import call
status, body = call("GET", "entities")
print("RESULT", status, body.get("caller"))
PYEND
)"
check "db-svc: graph_rag.call ходит в graph-rag-svc по mTLS ($(res "$out"))" test "$(res "$out")" = "RESULT 200 db-svc"

out="$(run_py main-chat-svc "$REPO/services/chat-svc/app:/app/app:ro" "${P}_chat-svc" -w /app \
    -e LLM_STREAM_URL=https://graph-rag-svc:8443/generate -e LLM_CANCEL_URL=https://graph-rag-svc:8443/cancel <<'PYEND'
import asyncio
from app.services.llm_service import LlmService

async def main():
    svc = LlmService()
    queued = await svc.enqueue_answer({"request_id": "r1"})
    cancelled = await svc.cancel("r1")
    print("RESULT", queued.get("status"), queued.get("caller"), cancelled.get("caller"))
asyncio.run(main())
PYEND
)"
check "chat-svc: LlmService.enqueue_answer / cancel по mTLS ($(res "$out"))" test "$(res "$out")" = "RESULT queued chat-svc chat-svc"

# тот же код chat-svc с сертификатом db-svc: политика отказывает (403), клиент поднимает ошибку
out="$(run_py main-chat-svc "$REPO/services/chat-svc/app:/app/app:ro" "${P}_db-svc" -w /app \
    -e LLM_STREAM_URL=https://graph-rag-svc:8443/generate <<'PYEND'
import asyncio
from app.services.llm_service import LlmService

async def main():
    try:
        await LlmService().enqueue_answer({"request_id": "r1"})
        print("RESULT принято")
    except Exception as exc:
        print("RESULT отказ", type(exc).__name__, getattr(exc.response, "status_code", ""))
asyncio.run(main())
PYEND
)"
check "chat-svc с чужим сертификатом (db-svc) получает отказ политики ($(res "$out"))" test "$(res "$out")" = "RESULT отказ HTTPStatusError 403"

out="$(run_py main-graph-rag-svc "$REPO/services/graph-rag-svc/app:/app/app:ro" "${P}_graph-rag-svc" -w /app \
    -e EMBEDDING_SVC_URL=https://embedding-svc:8443 -e DATABASE_URL=postgresql+asyncpg://x@localhost/x <<'PYEND'
import asyncio
from app.graph.embeddings import embed_texts_with_model
from app.core.startup_checks import _embedding_service_info

async def main():
    vectors, model = await embed_texts_with_model(["a", "b"])
    info = await _embedding_service_info()
    print("RESULT", len(vectors), len(vectors[0]), model, info.get("caller"))
asyncio.run(main())
PYEND
)"
check "graph-rag-svc: эмбеддинги и стартовая проверка embedding-svc по mTLS ($(res "$out"))" test "$(res "$out")" = "RESULT 2 8 stub-model graph-rag-svc"

out="$(run_py main-ingest-worker "$REPO/services/ingest-worker/app:/app/app:ro" "${P}_ingest-worker" -w /app \
    -e EMBEDDING_SVC_URL=https://embedding-svc:8443 -e EMBEDDING_DIM=8 -e DATABASE_URL=postgresql+asyncpg://x@localhost/x <<'PYEND'
import asyncio, sys
sys.path.insert(0, "/app/app")
import main as w

async def go():
    vectors, model = await w._embed(["a", "b"])
    print("RESULT", len(vectors), model)
asyncio.run(go())
PYEND
)"
check "ingest-worker: _embed ходит в embedding-svc по mTLS ($(res "$out"))" test "$(res "$out")" = "RESULT 2 stub-model"

echo "== обновление сертификата получателя и SIGHUP прокси"
fp() { docker run --rm --network "$NET" --entrypoint "" "${CERT_MOUNTS[@]}" -v "$HERE/policy_client.py:/policy_client.py:ro" "$PY" python /policy_client.py fingerprint graph-rag-svc 2>&1; }
before="$(fp)"
sleep 2
docker run --rm --pid "container:$P-graph-rag-svc-mtls" --user 0 --entrypoint "" --network "$NET" -v "${P}_graph-rag-svc:/certs" "$STEP_IMAGE" \
    step ca renew --force --ca-url https://step-ca:9000 --root /certs/root_ca.crt --exec "kill -HUP 1" /certs/tls.crt /certs/tls.key >/dev/null 2>&1
sleep 2
after="$(fp)"
check "прокси выдаёт новый сертификат после обновления и SIGHUP" test -n "$before" -a "$before" != "$after" -a "${#after}" -eq 64
check "после обновления клиент по-прежнему проходит рукопожатие (отпечаток получен)" test "${#after}" -eq 64

printf '\nИтого: %d проверок пройдено, %d провалено\n' "$pass" "$fail"
exit "$fail"
