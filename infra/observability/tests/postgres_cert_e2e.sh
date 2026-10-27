#!/usr/bin/env bash
# postgres_exporter входит в Postgres по клиентскому сертификату: одноразовые CA и Postgres с настоящим
# init.sql и pg_hba.pki.conf, роль monitoring_user в режиме cert (MONITORING_DB_AUTH=cert), настоящий
# образ экспортёра с параметрами из docker-compose.observability.dbcert.yml. Основной стек не затрагивается
# (префикс obspgc). Код возврата — число провалов.
#
#   infra/observability/tests/postgres_cert_e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
P=obspgc
export PKI_DIR="$TMP/pki" PKI_CA_CONTAINER="$P-ca" PKI_CA_VOLUME="${P}_ca_data"
source "$REPO/scripts/pki/lib.sh"
NET="$P-net"
PG="$P-postgres"
EXPORTER_IMAGE="$(grep -oE 'prometheuscommunity/postgres-exporter:[^ ]+' "$REPO/docker-compose.observability.yml" | head -1)"
SSL_PARAMS="$(grep -oE 'sslmode=verify-full[^"]*' "$REPO/docker-compose.observability.dbcert.yml" | head -1)"

pass=0; fail=0
expect() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  $1: ожидалось '$2', получено '$3'"; fi; }

cleanup() {
    docker rm -f "$PKI_CA_CONTAINER" "$PG" "$P-exporter" >/dev/null 2>&1
    docker volume rm -f "$PKI_CA_VOLUME" "${P}_srv" "${P}_mon" "${P}_other" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT
cleanup >/dev/null 2>&1; mkdir -p "$TMP"

[[ -n "$SSL_PARAMS" ]] || { echo "ПРОВАЛ  в оверлее нет параметров sslmode=verify-full"; exit 1; }

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
enroll() { "$REPO/scripts/pki/enroll.sh" "$@" >/dev/null 2>&1; }
enroll postgres --uid 999 --gid 999 --volume "${P}_srv" || { echo "ПРОВАЛ  сертификат сервера"; exit 1; }
enroll monitoring_user --uid 65534 --gid 65534 --volume "${P}_mon" || { echo "ПРОВАЛ  сертификат monitoring_user"; exit 1; }
enroll auth_user --uid 65534 --gid 65534 --volume "${P}_other" || { echo "ПРОВАЛ  сертификат auth_user"; exit 1; }

echo "== Postgres (monitoring_user — cert)"
docker run -d --name "$PG" --network "$NET" --network-alias postgres \
    -e POSTGRES_DB=app_db -e POSTGRES_USER=app_user -e POSTGRES_PASSWORD=adminpw-test \
    -e AUTH_DB_PASSWORD=pw-auth \
    -e INGEST_DB_PASSWORD= -e GRAPH_DB_PASSWORD= -e LIBRARY_DB_PASSWORD= -e CHAT_DB_PASSWORD= \
    -e DBSVC_DB_AUTH=cert -e CHAT_DB_AUTH=cert -e LIBRARY_DB_AUTH=cert -e INGEST_DB_AUTH=cert -e GRAPH_DB_AUTH=cert \
    -e MONITORING_DB_AUTH=cert \
    -v "$REPO/infra/db/init:/docker-entrypoint-initdb.d:ro" \
    -v "$REPO/infra/db/pg_hba.pki.conf:/etc/postgresql/pg_hba.conf:ro" \
    -v "${P}_srv:/pki:ro" pgvector/pgvector:pg16 \
    postgres -c ssl=on -c ssl_cert_file=/pki/tls.crt -c ssl_key_file=/pki/tls.key \
    -c ssl_ca_file=/pki/root_ca.crt -c hba_file=/etc/postgresql/pg_hba.conf >/dev/null
for _ in $(seq 1 90); do
    sleep 2
    docker exec "$PG" pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && break
    docker ps --format '{{.Names}}' | grep -qx "$PG" || break
done
docker exec "$PG" pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 \
    || { echo "ПРОВАЛ  Postgres не запустился:"; docker logs "$PG" 2>&1 | grep -E "FATAL|ERROR" | head -5; exit 1; }

# метрики экспортёра с сертификатом из тома $1; печатает строку pg_up
exporter_pg_up() {
    docker rm -f "$P-exporter" >/dev/null 2>&1
    docker run -d --name "$P-exporter" --network "$NET" --user 65534:65534 -v "$1:/pki:ro" \
        -e DATA_SOURCE_URI="postgres:5432/app_db?$SSL_PARAMS" -e DATA_SOURCE_USER=monitoring_user \
        "$EXPORTER_IMAGE" >/dev/null
    sleep 3
    docker run --rm --network "container:$P-exporter" --entrypoint "" pgvector/pgvector:pg16 \
        bash -c 'exec 3<>/dev/tcp/127.0.0.1/9187; printf "GET /metrics HTTP/1.0\r\n\r\n" >&3; cat <&3' 2>&1 | grep -m1 '^pg_up '
}

echo "== вход экспортёра по сертификату"
expect "monitoring_user: пароля нет" "" "$(docker exec "$PG" psql -U app_user -d app_db -At -c "SELECT rolpassword FROM pg_authid WHERE rolname='monitoring_user'")"
expect "monitoring_user входит по сертификату" "pg_up 1" "$(exporter_pg_up "${P}_mon")"
expect "сертификат другой роли (auth_user) отвергнут" "pg_up 0" "$(exporter_pg_up "${P}_other")"
docker logs "$P-exporter" 2>&1 | grep -qiE "certificate|authentication|password" \
    && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "ПРОВАЛ  в логах экспортёра нет причины отказа"; }

echo
echo "Итого: $pass проверок пройдено, $fail провалено"
exit "$fail"
