#!/usr/bin/env bash
# Сквозная проверка входа в Postgres по сертификатам: одноразовые CA и Postgres с настоящим
# init.sql, pg_hba.pki.conf и тем же набором ключей запуска, что в docker-compose.pki.yml.
# Настоящий стек не затрагивается (префикс pkipg). Код возврата — число провалов.
#
#   infra/pki/tests/postgres_cert_auth.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
P=pkipg
export PKI_DIR="$TMP/pki" PKI_CA_CONTAINER="$P-ca" PKI_CA_VOLUME="${P}_ca_data"
source "$REPO_ROOT/scripts/pki/lib.sh"
NET="${P}-net"
PG="$P-postgres"

pass=0; fail=0
check()     { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "ПРОВАЛ  $d"; fi; }
check_not() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail=$((fail+1)); echo "ПРОВАЛ  $d"; else pass=$((pass+1)); fi; }

cleanup() {
    docker rm -f "$PKI_CA_CONTAINER" "$PG" "$P-renewer" >/dev/null 2>&1
    docker volume rm -f "$PKI_CA_VOLUME" "${P}_srv" "${P}_dbsvc" "${P}_auth" "${P}_other" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT
cleanup >/dev/null 2>&1; mkdir -p "$TMP"

echo "== центр сертификации и сертификаты"
"$REPO_ROOT/scripts/pki/init.sh" >/dev/null 2>&1 || { echo "ПРОВАЛ  init.sh"; exit 1; }
docker network create "$NET" >/dev/null
docker run -d --name "$PKI_CA_CONTAINER" --network "$NET" --network-alias step-ca --entrypoint /bin/sh \
    -e PKI_CERT_TTL=24h -v "$PKI_CA_VOLUME:/home/step" -v "$REPO_ROOT/infra/pki/entrypoint.sh:/entrypoint.sh:ro" \
    "$STEP_IMAGE" /entrypoint.sh >/dev/null
for _ in $(seq 1 30); do
    docker exec "$PKI_CA_CONTAINER" step ca health --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt >/dev/null 2>&1 && break
    sleep 1
done
enroll() { "$REPO_ROOT/scripts/pki/enroll.sh" "$@" >/dev/null 2>&1; }
enroll postgres --uid 999 --gid 999 --volume "${P}_srv" || { echo "ПРОВАЛ  сертификат сервера"; exit 1; }
enroll dbsvc_user --volume "${P}_dbsvc"
enroll auth_user --volume "${P}_auth"
enroll chat_user --volume "${P}_other"   # сертификат другой роли

echo "== Postgres (dbsvc_user — cert, auth_user — password)"
docker run -d --name "$PG" --network "$NET" --network-alias postgres \
    -e POSTGRES_DB=app_db -e POSTGRES_USER=app_user -e POSTGRES_PASSWORD=adminpw-test \
    -e AUTH_DB_PASSWORD=pw-auth -e CHAT_DB_PASSWORD=pw-chat -e LIBRARY_DB_PASSWORD=pw-library \
    -e INGEST_DB_PASSWORD=pw-ingest -e GRAPH_DB_PASSWORD=pw-graph \
    -e DBSVC_DB_AUTH=cert -e CHAT_DB_AUTH=cert \
    -v "$REPO_ROOT/infra/db/init:/docker-entrypoint-initdb.d:ro" \
    -v "$REPO_ROOT/infra/db/pg_hba.pki.conf:/etc/postgresql/pg_hba.conf:ro" \
    -v "${P}_srv:/pki:ro" pgvector/pgvector:pg16 \
    postgres -c ssl=on -c ssl_cert_file=/pki/tls.crt -c ssl_key_file=/pki/tls.key \
    -c ssl_ca_file=/pki/root_ca.crt -c hba_file=/etc/postgresql/pg_hba.conf >/dev/null
for _ in $(seq 1 90); do
    sleep 2
    # Боевой сервер слушает TCP; временный сервер инициализации — только сокет.
    docker exec "$PG" pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && break
    docker ps --format '{{.Names}}' | grep -qx "$PG" || break
done
if ! docker exec "$PG" pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
    echo "ПРОВАЛ  Postgres не запустился:"; docker logs "$PG" 2>&1 | grep -E "FATAL|ERROR" | head -5; exit 1
fi

# --- клиенты: одноразовый контейнер с libpq; ключи клиентов принадлежат root, как требует libpq
ROOT="$PKI_DIR/root_ca.crt"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$TMP/rogue.key" \
    -out "$TMP/rogue.crt" -subj "/CN=dbsvc_user" -days 1 >/dev/null 2>&1
mkdir -p "$TMP/rogue" && cp "$TMP/rogue.crt" "$TMP/rogue/tls.crt" && cp "$TMP/rogue.key" "$TMP/rogue/tls.key" && cp "$TMP/rogue.crt" "$TMP/rogue/root_ca.crt"
chmod 600 "$TMP/rogue/tls.key"

# psql_as <роль> <пароль|-> <каталог/том сертификата|-> <sslmode> <корень: srv|rogue> <SQL>
psql_as() {
    local role=$1 pw=$2 vol=$3 mode=$4 rootsel=$5 sql=$6
    local mounts=(-v "$ROOT:/srvroot.crt:ro" -v "$TMP/rogue/root_ca.crt:/rogueroot.crt:ro")
    local rootfile=/srvroot.crt; [[ $rootsel == rogue ]] && rootfile=/rogueroot.crt
    local conn="host=postgres dbname=app_db user=$role sslmode=$mode sslrootcert=$rootfile"
    if [[ $vol != - ]]; then mounts+=(-v "$vol:/pki:ro"); conn+=" sslcert=/pki/tls.crt sslkey=/pki/tls.key"; fi
    local env=(); [[ $pw != - ]] && env=(-e "PGPASSWORD=$pw")
    docker run --rm --network "$NET" "${env[@]}" "${mounts[@]}" pgvector/pgvector:pg16 \
        psql "$conn" -At -c "$sql" 2>&1
}
who() { [[ "$(psql_as "$@" 'SELECT current_user')" == "${1}" ]]; }
local_sql() { docker exec "$PG" psql -U app_user -d app_db -At -c "$1"; }

echo "== вход по сертификату (dbsvc_user, chat_user — cert)"
check "dbsvc_user входит по своему сертификату (verify-full)" who dbsvc_user - "${P}_dbsvc" verify-full srv
check "chat_user входит по своему сертификату" who chat_user - "${P}_other" verify-full srv
check_not "dbsvc_user не входит по паролю (пароля у роли нет)" who dbsvc_user pw-dbsvc - verify-full srv
check_not "dbsvc_user с сертификатом другой роли отвергнут (CN ≠ роль)" who dbsvc_user - "${P}_auth" verify-full srv
check_not "сертификат чужого CA с CN=dbsvc_user отвергнут" who dbsvc_user - "$TMP/rogue" verify-full srv
check_not "клиент не доверяет серверу с чужим корнем (verify-full)" who dbsvc_user - "${P}_dbsvc" verify-full rogue
check "роль cert-режима без пароля в pg_authid" test "$(local_sql "SELECT rolpassword IS NULL FROM pg_authid WHERE rolname='dbsvc_user'")" = t

echo "== вход по паролю (auth_user — password) и общие запреты"
check "auth_user входит по паролю через TLS" who auth_user pw-auth - require srv
check_not "auth_user с неверным паролем отвергнут" who auth_user wrong - require srv
check_not "auth_user без пароля, только с сертификатом, отвергнут" who auth_user - "${P}_auth" verify-full srv
check_not "открытое соединение (sslmode=disable) отвергнуто, даже с верным паролем" who auth_user pw-auth - disable srv
check_not "суперпользователь по сети отвергнут" who app_user adminpw-test - require srv
check "суперпользователь работает через сокет контейнера" test "$(local_sql 'SELECT current_user')" = app_user
check "группы входа: pki_login = chat_user, dbsvc_user" test \
    "$(local_sql "SELECT string_agg(u.rolname, ',' ORDER BY u.rolname) FROM pg_auth_members m JOIN pg_roles g ON g.oid=m.roleid JOIN pg_roles u ON u.oid=m.member WHERE g.rolname='pki_login'")" = chat_user,dbsvc_user

echo "== смена режима роли через sync.sql"
sync_with() { docker exec -i "$@" "$PG" psql -U app_user -d app_db -v ON_ERROR_STOP=1 -q -f /docker-entrypoint-initdb.d/roles/sync.sql; }
sync_with -e DBSVC_DB_AUTH=password -e DBSVC_DB_PASSWORD=pw-dbsvc >/dev/null 2>&1
check "после перевода в password роль входит по паролю" who dbsvc_user pw-dbsvc - require srv
check_not "после перевода в password сертификат пароль не заменяет" who dbsvc_user - "${P}_dbsvc" verify-full srv
sync_with -e DBSVC_DB_AUTH=cert >/dev/null 2>&1
check "после возврата в cert роль снова входит по сертификату" who dbsvc_user - "${P}_dbsvc" verify-full srv
check_not "после возврата в cert пароль снова не работает" who dbsvc_user pw-dbsvc - verify-full srv
check_not "неверный *_DB_AUTH останавливает sync" sync_with -e DBSVC_DB_AUTH=certs
check_not "роль в режиме password без пароля останавливает sync" sync_with -e DBSVC_DB_AUTH=password -e DBSVC_DB_PASSWORD=

echo "== обновление серверного сертификата и SIGHUP"
serial() { docker exec "$PG" sh -c "openssl s_client -starttls postgres -connect 127.0.0.1:5432 </dev/null 2>/dev/null | openssl x509 -noout -serial"; }
before="$(serial)"
sleep 2
docker run --rm --pid "container:$PG" --user 0 --entrypoint "" --network "$NET" -v "${P}_srv:/certs" "$STEP_IMAGE" \
    step ca renew --force --ca-url https://step-ca:9000 --root /certs/root_ca.crt --exec "kill -HUP 1" /certs/tls.crt /certs/tls.key >/dev/null 2>&1
sleep 2
after="$(serial)"
check "Postgres выдаёт новый сертификат после обновления и SIGHUP" test -n "$before" -a "$before" != "$after"
check_not "перечитывание сертификата прошло без ошибок" bash -c "docker logs '$PG' 2>&1 | grep -qE 'could not load server certificate|private key file .* has (group|world) access|could not load private key'"
check "после обновления клиент по-прежнему входит" who dbsvc_user - "${P}_dbsvc" verify-full srv

echo "== db-svc с входом по сертификату"
IMG=main-db-svc:latest
if docker image inspect "$IMG" >/dev/null 2>&1; then
    run_dbsvc() {
        docker run --rm --network "$NET" -v "$REPO_ROOT/services/db-svc:/app" -v "$ROOT:/pkiroot/root_ca.crt:ro" \
            -v "${P}_dbsvc:/pki:ro" -v "$REPO_ROOT/../documents:/documents:ro" -e PYTHONDONTWRITEBYTECODE=1 \
            -e POSTGRES_HOST=postgres -e POSTGRES_USER=dbsvc_user -e POSTGRES_DB=app_db \
            -e POSTGRES_SSLCERT=/pki/tls.crt -e POSTGRES_SSLKEY=/pki/tls.key -e POSTGRES_SSLROOTCERT=/pkiroot/root_ca.crt \
            -e DBSVC_ADMIN_TOKEN=test-token -e GRAPH_RAG_URL=http://127.0.0.1:9 "$IMG" "$@"
    }
    out="$(run_dbsvc python -c "from app.services.pg import check_db_connection as c; r=c(); print(r.get('ok'), r.get('user'), r.get('auth'), r.get('error'))" 2>&1)"
    check "db-svc подключается по сертификату (получено: ${out##*$'\n'})" test "${out##*$'\n'}" = "True dbsvc_user certificate None"
    check "сквозной тест db-svc (журнал, CRUD, импорты) проходит по сертификату" bash -c \
        "$(declare -f run_dbsvc) ; NET='$NET' REPO_ROOT='$REPO_ROOT' ROOT='$ROOT' P='$P' IMG='$IMG' run_dbsvc python tests/test_audit.py | grep -q 'Провалов: 0'"
else
    echo "пропущено: нет образа $IMG (docker compose build db-svc)"
fi

printf '\nИтого: %d проверок пройдено, %d провалено\n' "$pass" "$fail"
exit "$fail"
