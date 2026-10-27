#!/usr/bin/env bash
# Проверка прав ingest_user на быстрые ответы и ссылки (init.sql/grants.sql и миграция 012)
# на одноразовом контейнере pgvector/pgvector:pg16. Основной стек docker compose не трогает.
#
#   bash tests/test_migration_012.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="mig012-test-$$"
FAILED=0

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

psql_q() { docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -d app_db -v ON_ERROR_STOP=1 -At "$@"; }

check() {  # check <описание> <ожидаемое> <фактическое>
    if [ "$2" == "$3" ]; then
        echo "ok   - $1"
    else
        echo "FAIL - $1: ожидалось '$2', получено '$3'"
        FAILED=1
    fi
}

priv() {  # priv <таблица> <право> -> t/f для ingest_user
    psql_q -c "SELECT has_table_privilege('ingest_user', '$1', '$2')"
}
col_priv() {  # col_priv <таблица> <колонка> <право>
    psql_q -c "SELECT has_column_privilege('ingest_user', '$1', '$2', '$3')"
}

docker run --rm -d --name "$NAME" \
    -e POSTGRES_PASSWORD=test -e POSTGRES_DB=app_db \
    -e AUTH_DB_PASSWORD=t -e CHAT_DB_PASSWORD=t -e LIBRARY_DB_PASSWORD=t \
    -e INGEST_DB_PASSWORD=t -e GRAPH_DB_PASSWORD=t -e DBSVC_DB_PASSWORD=t \
    -v "$ROOT/infra/db/init:/docker-entrypoint-initdb.d:ro" \
    pgvector/pgvector:pg16 >/dev/null

for _ in $(seq 1 90); do
    if docker logs "$NAME" 2>&1 | grep -q "PostgreSQL init process complete" \
       && docker exec "$NAME" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
docker logs "$NAME" 2>&1 | grep -q "PostgreSQL init process complete" || { echo "init.sql не отработал"; docker logs "$NAME" 2>&1 | tail -20; exit 1; }

expect_rights() {  # expect_rights <префикс описания>
    local p="$1"
    check "$p: SELECT quick_answer_variants" t "$(priv library.quick_answer_variants SELECT)"
    check "$p: SELECT links"                 t "$(priv library.links SELECT)"
    check "$p: SELECT quick_answers (is_active)" t "$(priv library.quick_answers SELECT)"
    for t in library.quick_answer_variants library.links; do
        check "$p: UPDATE embedding $t"       t "$(col_priv $t embedding UPDATE)"
        check "$p: UPDATE embedding_model $t" t "$(col_priv $t embedding_model UPDATE)"
        check "$p: нет INSERT $t"             f "$(priv $t INSERT)"
        check "$p: нет DELETE $t"             f "$(priv $t DELETE)"
    done
    check "$p: нет UPDATE text варианта"    f "$(col_priv library.quick_answer_variants text UPDATE)"
    check "$p: нет UPDATE url ссылки"       f "$(col_priv library.links url UPDATE)"
    check "$p: нет UPDATE is_active ссылки" f "$(col_priv library.links is_active UPDATE)"
    for a in INSERT UPDATE DELETE; do
        check "$p: нет $a quick_answers"    f "$(priv library.quick_answers $a)"
    done
}

# Чистая база: права выданы grants.sql из init
expect_rights "init"

# Рабочий сценарий воркера от имени ingest_user
psql_q >/dev/null <<'SQL'
INSERT INTO library.quick_answers (id, question, answer) VALUES ('00000000-0000-0000-0000-0000000000a1', 'q', 'a');
INSERT INTO library.quick_answer_variants (quick_answer_id, text) VALUES ('00000000-0000-0000-0000-0000000000a1', 'v');
INSERT INTO library.links (description, url) VALUES ('d', 'http://x');
SQL
WORKER="$(PGPASSWORD=t docker exec -i -e PGPASSWORD=t "$NAME" psql -h 127.0.0.1 -U ingest_user -d app_db -v ON_ERROR_STOP=1 -At <<SQL
SELECT v.id FROM library.quick_answer_variants v JOIN library.quick_answers qa ON qa.id = v.quick_answer_id
 WHERE v.embedding IS NULL AND qa.is_active ORDER BY v.id LIMIT 10 FOR UPDATE OF v SKIP LOCKED;
UPDATE library.quick_answer_variants SET embedding = array_fill(0.1::real, ARRAY[768])::vector, embedding_model = 'm';
SELECT id FROM library.links WHERE embedding IS NULL AND is_active ORDER BY id LIMIT 10 FOR UPDATE SKIP LOCKED;
UPDATE library.links SET embedding = array_fill(0.1::real, ARRAY[768])::vector, embedding_model = 'm';
SELECT 'worker-ok';
SQL
)"
echo "$WORKER" | grep -q worker-ok && echo "ok   - запросы воркера выполняются от ingest_user" \
    || { echo "FAIL - запросы воркера от ingest_user"; FAILED=1; }

# «Поднятая» база без новых прав: снимаем их и применяем миграцию
psql_q >/dev/null <<'SQL'
REVOKE ALL ON library.quick_answer_variants, library.links, library.quick_answers FROM ingest_user;
SQL
check "до миграции: нет UPDATE links" f "$(col_priv library.links embedding UPDATE)"

MIG="$ROOT/infra/db/migrations/012_notebook_grants.sql"
[ -f "$MIG" ] || { echo "FAIL - нет файла $MIG"; exit 1; }
docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -d app_db -v ON_ERROR_STOP=1 -q -f - < "$MIG" >/dev/null
expect_rights "после 012"

docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -d app_db -v ON_ERROR_STOP=1 -q -f - < "$MIG" >/dev/null \
    && echo "ok   - повторный запуск 012 без ошибок" || { echo "FAIL - повторный запуск 012"; FAILED=1; }
expect_rights "после повторного запуска"

if [ "$FAILED" -ne 0 ]; then echo "ПРОВАЛ"; exit 1; fi
echo "ВСЁ ПРОШЛО"
