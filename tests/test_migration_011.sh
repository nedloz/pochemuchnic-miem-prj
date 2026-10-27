#!/usr/bin/env bash
# Проверка миграции 011 на одноразовом контейнере pgvector/pgvector:pg16.
# Поднимает «старую» базу (init.sql с векторами 1024 + миграции 002-010), кладёт проиндексированный
# документ, применяет 011 и проверяет результат. Основной стек docker compose не трогает.
#
#   bash tests/test_migration_011.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="mig011-test-$$"
WORK="$(mktemp -d)"
FAILED=0

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
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

# Старая база: копия init с размерностью векторов 1024. Права/роли берутся из roles/ как есть.
cp -r "$ROOT/infra/db/init" "$WORK/init"
sed -i -E 's/^\\set embedding_dim +[0-9]+/\\set embedding_dim  1024/' "$WORK/init/init.sql"

docker run --rm -d --name "$NAME" \
    -e POSTGRES_PASSWORD=test -e POSTGRES_DB=app_db \
    -e AUTH_DB_PASSWORD=t -e CHAT_DB_PASSWORD=t -e LIBRARY_DB_PASSWORD=t \
    -e INGEST_DB_PASSWORD=t -e GRAPH_DB_PASSWORD=t -e DBSVC_DB_PASSWORD=t \
    -v "$WORK/init:/docker-entrypoint-initdb.d:ro" \
    pgvector/pgvector:pg16 >/dev/null

# Entrypoint временно поднимает сервер на сокете для init, потом перезапускает: ждём второй запуск.
for _ in $(seq 1 90); do
    if docker logs "$NAME" 2>&1 | grep -q "PostgreSQL init process complete" \
       && docker exec "$NAME" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
docker logs "$NAME" 2>&1 | grep -q "PostgreSQL init process complete" || { echo "init.sql не отработал"; docker logs "$NAME" 2>&1 | tail -20; exit 1; }

for f in "$ROOT"/infra/db/migrations/00[2-9]_*.sql "$ROOT"/infra/db/migrations/010_*.sql; do
    # 003 использует psql-переменную роли графа; остальным она не мешает
    docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -d app_db -v ON_ERROR_STOP=1 -q -f - < "$f" >/dev/null
done

check "до миграции: chunk_embeddings = 1024" 1024 \
    "$(psql_q -c "SELECT core.vector_column_dimension('library.chunk_embeddings','embedding')")"

# В настоящей старой базе новых таблиц нет (копия init.sql создала их с 1024): убираем.
psql_q -c "DROP TABLE library.quick_answer_variants, library.quick_answers, library.links" >/dev/null

# Один проиндексированный документ с чанком и вектором
psql_q >/dev/null <<'SQL'
INSERT INTO library.documents (id, title, category, source_type, content_type, ingest_status, ingest_attempts)
VALUES ('00000000-0000-0000-0000-0000000000d1', 'doc', 'c', 'upload', 'text/plain', 'indexed', 3);
INSERT INTO library.chunks (id, document_id, chunk_index, text)
VALUES ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000d1', 0, 'text');
INSERT INTO library.chunk_embeddings (chunk_id, embedding, embedding_model)
SELECT '00000000-0000-0000-0000-0000000000c1', array_fill(0.1::real, ARRAY[1024])::vector, 'old';
SQL

MIG="$ROOT/infra/db/migrations/011_notebook_pipeline.sql"
if [ ! -f "$MIG" ]; then
    echo "FAIL - нет файла $MIG"
    exit 1
fi
docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -d app_db -v ON_ERROR_STOP=1 -q -f - < "$MIG" >/dev/null

check "chunk_embeddings = 768" 768 \
    "$(psql_q -c "SELECT core.vector_column_dimension('library.chunk_embeddings','embedding')")"
check "chunk_embeddings очищена" 0 "$(psql_q -c "SELECT count(*) FROM library.chunk_embeddings")"
check "документ вернулся в pending" pending \
    "$(psql_q -c "SELECT ingest_status FROM library.documents WHERE id='00000000-0000-0000-0000-0000000000d1'")"
check "ingest_attempts обнулён" 0 \
    "$(psql_q -c "SELECT ingest_attempts FROM library.documents WHERE id='00000000-0000-0000-0000-0000000000d1'")"
check "три новые таблицы" 3 \
    "$(psql_q -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='library' AND table_name IN ('quick_answers','quick_answer_variants','links')")"
check "quick_answer_variants.embedding = 768" 768 \
    "$(psql_q -c "SELECT core.vector_column_dimension('library.quick_answer_variants','embedding')")"
check "links.embedding = 768" 768 \
    "$(psql_q -c "SELECT core.vector_column_dimension('library.links','embedding')")"
check "graph.entities.name_embedding остался 1024" 1024 \
    "$(psql_q -c "SELECT core.vector_column_dimension('graph.entities','name_embedding')")"
check "векторный индекс chunk_embeddings на месте" 1 \
    "$(psql_q -c "SELECT count(*) FROM pg_indexes WHERE schemaname='library' AND tablename='chunk_embeddings' AND indexname='idx_chunks_embedding_hnsw'")"

# Триггер уведомления: вставка/обновление строки без вектора шлёт ingest_jobs
NOTIFIED="$(psql_q <<'SQL'
LISTEN ingest_jobs;
BEGIN;
INSERT INTO library.quick_answers (id, question, answer) VALUES ('00000000-0000-0000-0000-0000000000a1', 'q', 'a');
INSERT INTO library.quick_answer_variants (quick_answer_id, text) VALUES ('00000000-0000-0000-0000-0000000000a1', 'v');
INSERT INTO library.links (description, url) VALUES ('d', 'http://x');
COMMIT;
SELECT 'done';
SQL
)"
echo "$NOTIFIED" | grep -q "done" || { echo "FAIL - вставка в новые таблицы"; FAILED=1; }
# Наличие триггеров
check "триггеры уведомления (2 шт.)" 2 \
    "$(psql_q -c "SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ('trg_quick_answer_variants_ingest_notify','trg_links_ingest_notify')")"

# Данные не пропадают при повторном запуске
psql_q -c "UPDATE library.documents SET ingest_status='indexed'" >/dev/null
docker exec -i -e PGOPTIONS="-c client_min_messages=warning" "$NAME" psql -U postgres -d app_db -v ON_ERROR_STOP=1 -q -f - < "$MIG" >/dev/null \
    && echo "ok   - повторный запуск 011 без ошибок" || { echo "FAIL - повторный запуск 011"; FAILED=1; }
check "повторный запуск не трогает проиндексированные документы" indexed \
    "$(psql_q -c "SELECT ingest_status FROM library.documents WHERE id='00000000-0000-0000-0000-0000000000d1'")"

if [ "$FAILED" -ne 0 ]; then echo "ПРОВАЛ"; exit 1; fi
echo "ВСЁ ПРОШЛО"
