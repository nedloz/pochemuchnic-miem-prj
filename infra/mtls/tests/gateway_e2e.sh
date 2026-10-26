#!/usr/bin/env bash
# Проверка mTLS шлюза и пользовательских сервисов: одноразовый CA; настоящий nginx.conf в режиме
# https с клиентским сертификатом шлюза; настоящие прокси перед auth-svc, chat-svc, library-svc и
# db-svc с боевыми конфигами (infra/mtls/*.conf); заглушки за ними (слушают только localhost);
# настоящий клиентский код chat-svc и graph-rag-svc. Стек не затрагивается (префикс gwtest).
# Код возврата — число провалов.
#
#   infra/mtls/tests/gateway_e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
NGX="$REPO/infra/nginx/tests"
TMP="$(mktemp -d)"
P=gwtest
export PKI_DIR="$TMP/pki" PKI_CA_CONTAINER="$P-ca" PKI_CA_VOLUME="${P}_ca_data"
source "$REPO/scripts/pki/lib.sh"
NET="$P-net"
PY=python:3.12-slim
CHAT_IMG=main-chat-svc
IDS=(nginx auth-svc chat-svc library-svc db-svc graph-rag-svc)
RECEIVERS=(auth-svc chat-svc library-svc db-svc)

pass=0; fail=0
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  $d"; fi; }

cleanup() {
    docker rm -f "$PKI_CA_CONTAINER" "$P-nginx" >/dev/null 2>&1
    for r in "${RECEIVERS[@]}"; do docker rm -f "$P-$r" "$P-$r-mtls" >/dev/null 2>&1; done
    for id in "${IDS[@]}"; do docker volume rm -f "${P}_$id" >/dev/null 2>&1; done
    docker volume rm -f "$PKI_CA_VOLUME" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT
cleanup >/dev/null 2>&1; mkdir -p "$TMP"

# --- ключи пользовательского контекста (тем же скриптом, что в проекте) ---------------------------------
KEYS="$TMP/keys"; mkdir -p "$KEYS"
python3 - "$REPO" "$KEYS" <<'PYEND'
import importlib.util, sys
from pathlib import Path
repo, keys = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("gen", repo / "scripts" / "gen_user_context_keys.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)
gen.OUT_DIR = keys
sys.argv = ["gen"]
gen.main()
PYEND
chmod -R a+rX "$KEYS"
MODULE="$REPO/services/auth-svc/app/user_context.py"

echo "== центр сертификации и сертификаты"
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
    -out "$TMP/rogue/tls.crt" -subj "/CN=nginx" -addext "subjectAltName=DNS:nginx" -days 1 >/dev/null 2>&1
chmod -R a+rX "$TMP/rogue"

echo "== получатели: заглушка на localhost + прокси с боевым конфигом"
receiver() { # имя
    local r=$1 image=$PY cmd=(python /srv/stubs.py) mode=echo
    [[ $r == auth-svc ]] && mode=auth
    if [[ $r == chat-svc ]]; then image=$CHAT_IMG; cmd=(python /srv/ws_stub.py); fi
    docker run -d --name "$P-$r" --network "$NET" --network-alias "$r" --entrypoint "" \
        -v "$MODULE:/srv/user_context.py:ro" -v "$NGX/stubs.py:/srv/stubs.py:ro" -v "$NGX/ws_stub.py:/srv/ws_stub.py:ro" \
        -v "$KEYS/master.key:/run/secrets/master:ro" -v "$KEYS/$r.key:/run/secrets/user_context_key:ro" \
        -e STUB="$mode" -e BIND=127.0.0.1 -e USER_CONTEXT_AUDIENCE="$r" -e USER_CONTEXT_KEY_FILE=/run/secrets/user_context_key \
        -e PYTHONDONTWRITEBYTECODE=1 "$image" "${cmd[@]}" >/dev/null
    docker run -d --name "$P-$r-mtls" --network "container:$P-$r" \
        -v "${P}_$r:/pki-svc:ro" -v "$REPO/infra/mtls/$r.conf:/etc/nginx/conf.d/default.conf:ro" \
        nginx:1.27-alpine >/dev/null
}
for r in "${RECEIVERS[@]}"; do receiver "$r"; done

echo "== шлюз: настоящий nginx.conf, режим https"
docker run -d --name "$P-nginx" --network "$NET" --network-alias nginx \
    -e NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx -e UPSTREAM_SCHEME=https -e UPSTREAM_PORT=8443 \
    -v "$REPO/infra/nginx/nginx.conf:/etc/nginx/templates/nginx.conf.template:ro" \
    -v "${P}_nginx:/pki-svc:ro" -v "$REPO/infra/nginx/backend_tls.conf:/etc/nginx/backend_tls/tls.conf:ro" \
    nginx:1.27-alpine >/dev/null
sleep 4
for c in "$P-nginx" "$P-auth-svc-mtls" "$P-chat-svc-mtls" "$P-library-svc-mtls" "$P-db-svc-mtls"; do
    if ! docker exec "$c" nginx -t >/dev/null 2>&1; then
        echo "ПРОВАЛ  nginx -t ($c):"; docker exec "$c" nginx -t 2>&1 | tail -4; fail=$((fail + 1))
    fi
done

echo "== пользовательские сценарии через шлюз по mTLS (тот же набор, что в user_context_e2e.sh)"
out="$(docker run --rm --network "$NET" --entrypoint "" \
    -v "$MODULE:/srv/user_context.py:ro" -v "$NGX/client_checks.py:/client_checks.py:ro" \
    -v "$KEYS/master.key:/run/secrets/master:ro" "$PY" python /client_checks.py 2>&1)"
rc=$?
echo "$out" | grep -v "^Провалов"
if [[ $rc -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi

echo "== политика каждой пары и невозможность обхода"
MOUNTS=(-v "$ROOT:/certs/root_ca.crt:ro" -v "$TMP/rogue:/certs/rogue:ro")
for id in "${IDS[@]}"; do MOUNTS+=(-v "${P}_$id:/certs/$id:ro"); done
out="$(docker run --rm --network "$NET" --entrypoint "" "${MOUNTS[@]}" -v "$HERE/gateway_policy.py:/gateway_policy.py:ro" \
    "$CHAT_IMG" python /gateway_policy.py 2>&1)"
rc=$?
echo "$out" | grep -v "^Провалов"
if [[ $rc -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi

echo "== настоящий клиентский код сервисов"
res() { grep -o 'RESULT.*' <<<"$1" | head -1; }
out="$(docker run --rm -i --network "$NET" --entrypoint "" -w /app -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$REPO/services/chat-svc/app:/app/app:ro" -v "${P}_chat-svc:/pki-svc:ro" \
    -e SERVICE_MTLS_CERT=/pki-svc/tls.crt -e SERVICE_MTLS_KEY=/pki-svc/tls.key -e SERVICE_MTLS_CA=/pki-svc/root_ca.crt \
    -e AUTH_PROFILE_URL='https://auth-svc:8443/internal/users/{user_id}/profile' \
    "$CHAT_IMG" python - 2>&1 <<'PYEND'
import asyncio
from app.services.auth_service import AuthService

async def main():
    profile = await AuthService().get_profile("11111111-1111-1111-1111-111111111111")
    print("RESULT", profile.get("caller"))
asyncio.run(main())
PYEND
)"
check "chat-svc: AuthService.get_profile ходит в auth-svc по mTLS ($(res "$out"))" test "$(res "$out")" = "RESULT chat-svc"

out="$(docker run --rm -i --network "$NET" --entrypoint "" -w /app -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$REPO/services/graph-rag-svc/app:/app/app:ro" -v "${P}_graph-rag-svc:/pki-svc:ro" \
    -e SERVICE_MTLS_CERT=/pki-svc/tls.crt -e SERVICE_MTLS_KEY=/pki-svc/tls.key -e SERVICE_MTLS_CA=/pki-svc/root_ca.crt \
    -e CHAT_WS_URL=wss://chat-svc:8443/ws/internal/llm -e DATABASE_URL=postgresql+asyncpg://x@localhost/x \
    main-graph-rag-svc python - 2>&1 <<'PYEND'
import asyncio, json, websockets
from app.core.config import settings
from app.generation.job_queue import _tls_kwargs

async def main():
    async with websockets.connect(settings.chat_ws_url, **_tls_kwargs()) as ws:
        first = json.loads(await asyncio.wait_for(ws.recv(), 6))
    print("RESULT", first.get("caller"), first.get("path"))
asyncio.run(main())
PYEND
)"
check "graph-rag-svc: внутренний WebSocket в chat-svc по mTLS ($(res "$out"))" test "$(res "$out")" = "RESULT graph-rag-svc /ws/internal/llm"

echo "== обновление сертификата шлюза и SIGHUP"
workers() { docker exec "$P-nginx" sh -c "ps | grep 'nginx: worker' | grep -v grep | awk '{print \$1}' | sort | tr '\n' ' '"; }
workers_before="$(workers)"
docker run --rm --pid "container:$P-nginx" --user 0 --entrypoint "" --network "$NET" -v "${P}_nginx:/certs" "$STEP_IMAGE" \
    step ca renew --force --ca-url https://step-ca:9000 --root /certs/root_ca.crt --exec "kill -HUP 1" /certs/tls.crt /certs/tls.key >/dev/null 2>&1
sleep 2
# nginx пишет «signal 1 (SIGHUP)» на уровне notice, а в конфиге стоит warn, поэтому о перечитывании
# судим по тому, что воркеры перезапущены (при reload master создаёт новых).
workers_after="$(workers)"
check "шлюз перечитал сертификат: воркеры перезапущены (SIGHUP)" test -n "$workers_before" -a "$workers_before" != "$workers_after"
code="$(docker run --rm --network "$NET" --entrypoint "" "$PY" python -c "
import urllib.request
r = urllib.request.Request('http://nginx/api/library/tree', headers={'Authorization': 'Bearer user-token'})
print(urllib.request.urlopen(r).status)" 2>&1 | tail -1)"
check "после обновления шлюз по-прежнему ходит в сервисы по mTLS ($code)" test "$code" = 200

printf '\nИтого: %d проверок пройдено, %d провалено\n' "$pass" "$fail"
exit "$fail"
