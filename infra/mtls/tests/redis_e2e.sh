#!/usr/bin/env bash
# Проверка Redis за mTLS-прокси: настоящий redis:7 с ACL-файлом из scripts/gen_redis_acl.py,
# nginx stream с боевым конфигом infra/mtls/redis.conf и настоящий клиентский код auth-svc и
# chat-svc (app/redis_tls.py). Стек не затрагивается (префикс redistst). Код возврата — число провалов.
#
#   infra/mtls/tests/redis_e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
P=redistst
export PKI_DIR="$TMP/pki" PKI_CA_CONTAINER="$P-ca" PKI_CA_VOLUME="${P}_ca_data"
source "$REPO/scripts/pki/lib.sh"
NET="$P-net"
IDS=(redis auth-svc chat-svc db-svc redis-exporter)

pass=0; fail=0
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  $d"; fi; }
expect() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  $1: ожидалось '$2', получено '$3'"; fi; }

cleanup() {
    docker rm -f "$PKI_CA_CONTAINER" "$P-redis" "$P-redis-mtls" "$P-exporter" >/dev/null 2>&1
    for id in "${IDS[@]}"; do docker volume rm -f "${P}_$id" >/dev/null 2>&1; done
    docker volume rm -f "$PKI_CA_VOLUME" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT
cleanup >/dev/null 2>&1; mkdir -p "$TMP"

echo "== центр сертификации, сертификаты, ACL"
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
    uid=(); [[ "$id" == redis-exporter ]] && uid=(--uid 59000 --gid 59000)
    "$REPO/scripts/pki/enroll.sh" "$id" --volume "${P}_$id" "${uid[@]}" >/dev/null 2>&1 || { echo "ПРОВАЛ  сертификат $id"; exit 1; }
done
REDIS_ACL_FILE="$TMP/users.acl" REDIS_ENV_FILE="$TMP/env" python3 "$REPO/scripts/gen_redis_acl.py" >/dev/null
chmod a+r "$TMP/users.acl"
source "$TMP/env"
check "в ACL нет паролей открытым текстом" bash -c "! grep -q '$REDIS_AUTH_PASSWORD' '$TMP/users.acl'"

echo "== redis + прокси с боевым конфигом"
docker run -d --name "$P-redis" --network "$NET" --network-alias redis -v "$TMP/users.acl:/etc/redis/users.acl:ro" \
    redis:7 redis-server --bind 127.0.0.1 --port 6379 --aclfile /etc/redis/users.acl >/dev/null
docker run -d --name "$P-redis-mtls" --network "container:$P-redis" -v "${P}_redis:/pki-svc:ro" \
    -v "$REPO/infra/mtls/redis.conf:/etc/nginx/nginx.conf:ro" nginx:1.27-alpine >/dev/null
sleep 3
check "nginx -t" docker exec "$P-redis-mtls" nginx -t

echo "== настоящий клиентский код auth-svc и chat-svc"
run_py() { # образ, каталог кода, том сертификата, пароль, пользователь; код на stdin
    local image=$1 code=$2 vol=$3 user=$4 pass=$5
    docker run --rm -i --network "$NET" --entrypoint "" -w /app -e PYTHONDONTWRITEBYTECODE=1 \
        -v "$code" -v "$vol:/pki-svc:ro" \
        -e SERVICE_MTLS_CERT=/pki-svc/tls.crt -e SERVICE_MTLS_KEY=/pki-svc/tls.key -e SERVICE_MTLS_CA=/pki-svc/root_ca.crt \
        -e "URL=rediss://$user:$pass@redis:6380/0" "$image" python - 2>&1
}
res() { grep -o 'RESULT.*' <<<"$1" | head -1; }
AUTH_CODE="$REPO/services/auth-svc/app:/app/app:ro"
CHAT_CODE="$REPO/services/chat-svc/app:/app/app:ro"

PROBE='
import asyncio, os
from redis.exceptions import RedisError
from app.redis_tls import make_client
async def attempt(c, coro):
    try:
        await coro; return "ok"
    except RedisError as e:
        m = str(e).lower()
        return "NOPERM" if "permission" in m else "AUTHFAIL" if ("invalid" in m or "wrongpass" in m) else str(e)[:30]
    except Exception as e:
        return type(e).__name__
async def main():
    c = make_client(os.environ["URL"])
    r = [await attempt(c, c.set("auth:k", "1")), await attempt(c, c.set("ws:k", "1")),
         await attempt(c, c.set("chat:k", "1")), await attempt(c, c.flushall()),
         await attempt(c, c.config_get("*")), await attempt(c, c.keys("*"))]
    print("RESULT", *r)
asyncio.run(main())
'
out="$(run_py main-auth-svc "$AUTH_CODE" "${P}_auth-svc" auth-svc "$REDIS_AUTH_PASSWORD" <<<"$PROBE")"
expect "auth-svc: свой префикс да, чужие и опасные команды нет ($(res "$out"))" "RESULT ok NOPERM NOPERM NOPERM NOPERM NOPERM" "$(res "$out")"
out="$(run_py main-chat-svc "$CHAT_CODE" "${P}_chat-svc" chat-svc "$REDIS_CHAT_PASSWORD" <<<"$PROBE")"
expect "chat-svc: свои префиксы да, auth: нет ($(res "$out"))" "RESULT NOPERM ok ok NOPERM NOPERM NOPERM" "$(res "$out")"

out="$(run_py main-auth-svc "$AUTH_CODE" "${P}_auth-svc" auth-svc wrong-password <<<"$PROBE")"
expect "неверный пароль ACL" "RESULT AUTHFAIL AUTHFAIL AUTHFAIL AUTHFAIL AUTHFAIL AUTHFAIL" "$(res "$out")"

# чужой сертификат (db-svc): соединение сбрасывается прокси, до Redis не доходит
out="$(run_py main-auth-svc "$AUTH_CODE" "${P}_db-svc" auth-svc "$REDIS_AUTH_PASSWORD" <<<'
import asyncio, os
from app.redis_tls import make_client
async def main():
    try:
        await make_client(os.environ["URL"]).ping(); print("RESULT принято")
    except Exception as e: print("RESULT отказ")
asyncio.run(main())')"
expect "сертификат db-svc не пускают" "RESULT отказ" "$(res "$out")"

# redis_exporter с боевыми переменными docker-compose.observability.mtls.yml: ACL-пользователь prometheus
EXPORTER_IMAGE="$(grep -oE 'oliver006/redis_exporter:[^ ]+' "$REPO/docker-compose.observability.yml" | head -1)"
exporter_up() { # том сертификата, пароль, [пользователь контейнера] -> метрики экспортёра
    docker rm -f "$P-exporter" >/dev/null 2>&1
    docker run -d --name "$P-exporter" --network "$NET" --user "${3:-59000:59000}" -v "$1:/pki-svc:ro" \
        -e REDIS_ADDR=rediss://redis:6380 -e REDIS_USER=prometheus -e REDIS_PASSWORD="$2" \
        -e REDIS_EXPORTER_TLS_CLIENT_CERT_FILE=/pki-svc/tls.crt -e REDIS_EXPORTER_TLS_CLIENT_KEY_FILE=/pki-svc/tls.key \
        -e REDIS_EXPORTER_TLS_CA_CERT_FILE=/pki-svc/root_ca.crt "$EXPORTER_IMAGE" >/dev/null
    sleep 2
    docker run --rm --network "container:$P-exporter" --entrypoint "" main-auth-svc python -c \
        "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:9121/metrics',timeout=10).read().decode())" 2>&1
}
metrics="$(exporter_up "${P}_redis-exporter" "$REDIS_PROMETHEUS_PASSWORD")"
expect "redis-exporter: redis_up 1 по mTLS" "redis_up 1" "$(grep -m1 '^redis_up ' <<<"$metrics")"
check "redis-exporter: доступны память и ключи" grep -q '^redis_memory_used_bytes' <<<"$metrics"
expect "redis-exporter: неверный пароль prometheus" "redis_up 0" "$(exporter_up "${P}_redis-exporter" wrong | grep -m1 '^redis_up ')"
expect "redis-exporter: чужой сертификат (db-svc)" "redis_up 0" "$(exporter_up "${P}_db-svc" "$REDIS_PROMETHEUS_PASSWORD" 0:0 | grep -m1 '^redis_up ')"
out="$(run_py main-auth-svc "$AUTH_CODE" "${P}_redis-exporter" prometheus "$REDIS_PROMETHEUS_PASSWORD" <<<'
import asyncio, os
from redis.exceptions import RedisError
from app.redis_tls import make_client
async def attempt(coro):
    try:
        await coro; return "ok"
    except RedisError as e:
        return "NOPERM" if "permission" in str(e).lower() else str(e)[:30]
async def main():
    c = make_client(os.environ["URL"])
    print("RESULT", await attempt(c.info()), await attempt(c.set("auth:k", "1")), await attempt(c.get("auth:k")),
          await attempt(c.keys("*")), await attempt(c.flushall()), await attempt(c.config_set("maxmemory", "1")))
asyncio.run(main())')"
expect "пользователь prometheus: только чтение статистики ($(res "$out"))" "RESULT ok NOPERM NOPERM NOPERM NOPERM NOPERM" "$(res "$out")"

# без сертификата, по обычному TCP и напрямую в Redis мимо прокси
out="$(docker run --rm -i --network "$NET" --entrypoint "" -v "${P}_auth-svc:/pki-svc:ro" -e "PW=$REDIS_AUTH_PASSWORD" main-auth-svc python - 2>&1 <<'PYEND'
import os, socket, ssl
ctx = ssl.create_default_context(cafile="/pki-svc/root_ca.crt")
try:
    s = socket.create_connection(("redis", 6380), 5); w = ctx.wrap_socket(s, server_hostname="redis")
    w.sendall(b"PING\r\n"); data = w.recv(64)
    print("RESULT без сертификата отказ" if not data else "RESULT без сертификата принято")
except Exception as e: print("RESULT без сертификата отказ")
try:
    socket.create_connection(("redis", 6379), 3).close(); print("RESULT напрямую доступен")
except OSError: print("RESULT напрямую отказ")
PYEND
)"
expect "без клиентского сертификата" "RESULT без сертификата отказ" "$(grep -o 'RESULT без.*' <<<"$out" | head -1)"
expect "порт Redis мимо прокси закрыт" "RESULT напрямую отказ" "$(grep -o 'RESULT напрямую.*' <<<"$out" | head -1)"

# обновление сертификата клиента: новое соединение берёт файлы с диска заново, а не закешированный контекст
out="$(run_py main-auth-svc "$AUTH_CODE" "${P}_auth-svc" auth-svc "$REDIS_AUTH_PASSWORD" <<<'
import asyncio, os, shutil
os.makedirs("/tmp/c")
for f in ("tls.crt", "tls.key", "root_ca.crt"): shutil.copy("/pki-svc/" + f, "/tmp/c/" + f)
os.environ["SERVICE_MTLS_CERT"] = "/tmp/c/tls.crt"; os.environ["SERVICE_MTLS_KEY"] = "/tmp/c/tls.key"
from app.redis_tls import make_client
async def main():
    c = make_client(os.environ["URL"])
    await c.ping()
    good = open("/tmp/c/tls.crt").read()
    open("/tmp/c/tls.crt", "w").write("не сертификат")
    await c.connection_pool.disconnect()
    try:
        await c.ping(); broken = "кеш контекста"
    except Exception:
        broken = "перечитал файлы"
    open("/tmp/c/tls.crt", "w").write(good)
    await c.connection_pool.disconnect()
    await c.ping()
    print("RESULT", broken, "и снова работает")
asyncio.run(main())')"
expect "новое соединение перечитывает сертификат" "RESULT перечитал файлы и снова работает" "$(res "$out")"

echo
echo "Итого: $pass проверок пройдено, $fail провалено"
exit "$fail"
