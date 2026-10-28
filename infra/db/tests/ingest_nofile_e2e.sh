#!/usr/bin/env bash
# IVHR-1 и IVHR-22 на настоящем Postgres: одноразовая база с боевым init.sql и ролями, настоящий код
# ingest-worker, db-svc и library-svc под их ролями. Основной стек не затрагивается (префикс nofile).
#   - документы без файла в очереди получают понятную ошибку и метрику no_file, с отсрочкой;
#   - привязка файла (ATTACH_FILE_SQL из db-svc) ставит документ в очередь и будит воркер;
#   - отпечаток дерева библиотеки меняется вместе с деревом и не реагирует на посторонние правки.
# Образы main-ingest-worker, main-db-svc, main-library-svc должны быть собраны (docker compose build).
#   infra/db/tests/ingest_nofile_e2e.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
P=nofile; NET="$P-net"; PG="$P-postgres"
PW=pw-$RANDOM$RANDOM

pass=0; fail=0
expect() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  $1: ожидалось '$2', получено '$3'"; fi; }
cleanup() { docker rm -f "$PG" >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
trap cleanup EXIT
cleanup; docker network create "$NET" >/dev/null

echo "== Postgres с боевым init.sql и ролями"
docker run -d --name "$PG" --network "$NET" --network-alias postgres \
    -e POSTGRES_DB=app_db -e POSTGRES_USER=app_user -e POSTGRES_PASSWORD="$PW" \
    -e AUTH_DB_PASSWORD="$PW" -e CHAT_DB_PASSWORD="$PW" -e LIBRARY_DB_PASSWORD="$PW" \
    -e INGEST_DB_PASSWORD="$PW" -e GRAPH_DB_PASSWORD="$PW" -e DBSVC_DB_PASSWORD="$PW" \
    -v "$REPO/infra/db/init:/docker-entrypoint-initdb.d:ro" pgvector/pgvector:pg16 >/dev/null
for _ in $(seq 1 90); do
    sleep 2
    docker exec "$PG" pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && break
    docker ps --format '{{.Names}}' | grep -qx "$PG" || break
done
docker exec "$PG" pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 \
    || { echo "ПРОВАЛ  Postgres не запустился"; docker logs "$PG" 2>&1 | grep -E "FATAL|ERROR" | head -5; exit 1; }
sql() { docker exec -i "$PG" psql -U app_user -d app_db -v ON_ERROR_STOP=1 -q -At -c "$1"; }

D_OLD=00000000-0000-0000-0000-00000000a001   # pending, без файла, создан давно
D_NEW=00000000-0000-0000-0000-00000000a002   # pending, без файла, только что
D_OK=00000000-0000-0000-0000-00000000a003    # pending, с файлом
D_DONE=00000000-0000-0000-0000-00000000a004  # indexed, с файлом
sql "
INSERT INTO library.documents (id, title, category, source_type, content_type, created_at) VALUES
  ('$D_OLD', 'Без файла давно', 'c', 's', 'application/pdf', now() - interval '1 hour'),
  ('$D_NEW', 'Без файла только что', 'c', 's', 'application/pdf', now()),
  ('$D_OK',  'С файлом', 'c', 's', 'application/pdf', now() - interval '1 hour'),
  ('$D_DONE','Проиндексирован', 'c', 's', 'application/pdf', now() - interval '1 hour');
UPDATE library.documents SET ingest_status = 'indexed', checksum = 'old' WHERE id = '$D_DONE';
INSERT INTO library.document_files (document_id, storage_backend, bucket, storage_key, storage_path, file_name, mime_type, size_bytes, sha256_hash)
SELECT id, 'minio', 'documents', 'k/' || id, 'k/' || id, 'a.pdf', 'application/pdf', 1, 'h' FROM library.documents WHERE id IN ('$D_OK', '$D_DONE');
" || { echo "ПРОВАЛ  начальные данные"; exit 1; }

py() { # образ, код сервиса, переменные окружения..., код на stdin
    local image=$1 code=$2; shift 2
    docker run --rm -i --network "$NET" --entrypoint "" -e PYTHONDONTWRITEBYTECODE=1 -v "$code" "$@" "$image" python - 2>&1
}
res() { grep -o 'RESULT.*' <<<"$1" | head -1; }

echo "== ingest-worker: документы без файла"
worker() {
    py main-ingest-worker "$REPO/services/ingest-worker/app:/app/app:ro" -w /app/app \
        -e DATABASE_URL="postgresql+asyncpg://ingest_user:$PW@postgres:5432/app_db" -e EMBEDDING_SVC_URL=http://x:1 -e EMBEDDING_DIM=768 \
        -e INGEST_NO_FILE_GRACE_SEC="${1:-300}" <<'PYEND'
import asyncio, main as w
print("RESULT", asyncio.run(w.flag_documents_without_file()))
PYEND
}
expect "число pending без файла" "RESULT 2" "$(res "$(worker)")"
expect "старому документу записана ошибка" "1" "$(sql "SELECT count(*) FROM library.documents WHERE id='$D_OLD' AND ingest_error LIKE 'К документу не привязан файл%'")"
expect "свежий документ в пределах отсрочки не помечен" "" "$(sql "SELECT ingest_error FROM library.documents WHERE id='$D_NEW'")"
expect "документ с файлом не помечен" "0" "$(sql "SELECT count(*) FROM library.documents WHERE id IN ('$D_OK','$D_DONE') AND ingest_error IS NOT NULL")"
expect "статус остался pending" "pending" "$(sql "SELECT ingest_status FROM library.documents WHERE id='$D_OLD'")"
expect "после отсрочки помечается и второй" "RESULT 2" "$(res "$(worker 0)")"
expect "второму тоже записана ошибка" "2" "$(sql "SELECT count(*) FROM library.documents WHERE ingest_error LIKE 'К документу не привязан файл%'")"

echo "== db-svc: привязка файла ставит документ в очередь"
attach() { # документ, checksum
    py main-db-svc "$REPO/services/db-svc/app:/app/app:ro" -w /app \
        -e POSTGRES_HOST=postgres -e POSTGRES_DB=app_db -e POSTGRES_USER=dbsvc_user -e POSTGRES_PASSWORD="$PW" \
        -e DOC="$1" -e SUM="$2" <<'PYEND'
import os
from app.services.minio_import_placeholder import ATTACH_FILE_SQL
from app.services.pg import get_conn
with get_conn() as conn:
    with conn.cursor() as cur:
        cur.execute(ATTACH_FILE_SQL, (os.environ["SUM"],) * 3 + (os.environ["DOC"],))
        print("RESULT", cur.rowcount)
    conn.commit()
PYEND
}
listen() { # ждёт NOTIFY от триггера в течение 5 секунд
    docker exec -i "$PG" bash -c "{ echo 'LISTEN ingest_jobs;'; sleep 5; echo 'SELECT 1;'; } | psql -U app_user -d app_db -q" 2>&1 &
}
out_file=$(mktemp); listen >"$out_file"; sleep 1
expect "привязка к документу без файла" "RESULT 1" "$(res "$(attach "$D_OLD" new-sum)")"
wait
grep -q "ingest_jobs" "$out_file" && notified=да || notified=нет; rm -f "$out_file"
expect "воркер разбужен NOTIFY" "да" "$notified"
expect "ошибка о файле снята, статус pending, checksum записан" "pending||published|new-sum" \
    "$(sql "SELECT ingest_status || '|' || coalesce(ingest_error, '') || '|' || status || '|' || checksum FROM library.documents WHERE id='$D_OLD'")"
expect "тот же файл у проиндексированного документа не переиндексируется" "indexed" \
    "$(attach "$D_DONE" old >/dev/null; sql "SELECT ingest_status FROM library.documents WHERE id='$D_DONE'")"
expect "заменённый файл возвращает документ в очередь" "pending|0" \
    "$(attach "$D_DONE" changed >/dev/null; sql "SELECT ingest_status || '|' || ingest_attempts FROM library.documents WHERE id='$D_DONE'")"

echo "== library-svc: отпечаток дерева"
sql "INSERT INTO library.topics (id, name, slug) VALUES ('00000000-0000-0000-0000-00000000b001', 'Учёба', 'study');" >/dev/null
fingerprint() {
    res "$(py main-library-svc "$REPO/services/library-svc/app:/code/app:ro" -w /code \
        -e DATABASE_URL="postgresql+asyncpg://library_user:$PW@postgres:5432/app_db" <<'PYEND'
import asyncio
from app.database import AsyncSessionLocal
from app.services import library_tree_fingerprint
async def main():
    async with AsyncSessionLocal() as s:
        print("RESULT", await library_tree_fingerprint(s))
asyncio.run(main())
PYEND
)"
}
f0=$(fingerprint)
[[ "$f0" =~ ^RESULT\ [0-9a-f]{32}$ ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "ПРОВАЛ  отпечаток не посчитан: $f0"; }
expect "отпечаток стабилен" "$f0" "$(fingerprint)"
sql "UPDATE library.documents SET ingest_status = 'failed', updated_at = now() WHERE id = '$D_OK'" >/dev/null
expect "статус индексации и updated_at не влияют" "$f0" "$(fingerprint)"
sql "UPDATE library.topics SET name = 'Учёба 2'" >/dev/null; f1=$(fingerprint)
[ "$f1" != "$f0" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "ПРОВАЛ  переименование темы не меняет отпечаток"; }
sql "UPDATE library.documents SET topic_id = '00000000-0000-0000-0000-00000000b001' WHERE id = '$D_OK'" >/dev/null; f2=$(fingerprint)
[ "$f2" != "$f1" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "ПРОВАЛ  перенос документа в тему не меняет отпечаток"; }
sql "INSERT INTO library.document_relations (from_document_id, to_document_id, relation_type) VALUES ('$D_OK', '$D_DONE', 'related')" >/dev/null; f3=$(fingerprint)
[ "$f3" != "$f2" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "ПРОВАЛ  новая связь не меняет отпечаток"; }
sql "DELETE FROM library.documents WHERE id = '$D_NEW'" >/dev/null; f4=$(fingerprint)
[ "$f4" != "$f3" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "ПРОВАЛ  удаление документа не меняет отпечаток"; }

echo
echo "Итого: $pass проверок пройдено, $fail провалено"
exit "$fail"
