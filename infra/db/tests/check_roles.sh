#!/usr/bin/env bash
# Проверка прав ролей Postgres: что каждому сервису можно и, что важнее, нельзя.
#
#   infra/db/tests/check_roles.sh [контейнер]        # по умолчанию контейнер postgres
#
# Каждая проверка выполняется в транзакции под SET LOCAL ROLE и откатывается, данные базы
# не меняются. Пароли ролей читаются из окружения контейнера (как их видит sync.sql).
# Код возврата — число проваленных проверок.
set -u

C="${1:-postgres}"
ADMIN="${POSTGRES_ADMIN_USER:-$(docker exec "$C" printenv POSTGRES_USER)}"
DB="${POSTGRES_DB:-$(docker exec "$C" printenv POSTGRES_DB)}"

env_or() { docker exec "$C" printenv "$1" 2>/dev/null || echo "$2"; }
AUTH=$(env_or AUTH_DB_USER auth_user);       CHAT=$(env_or CHAT_DB_USER chat_user)
LIB=$(env_or LIBRARY_DB_USER library_user);  ING=$(env_or INGEST_DB_USER ingest_user)
GRAPH=$(env_or GRAPH_DB_USER graph_user);    DBS=$(env_or DBSVC_DB_USER dbsvc_user)

pass=0; fail=0

psql_admin() { docker exec -i "$C" psql -U "$ADMIN" -d "$DB" -v ON_ERROR_STOP=1 -q -At "$@"; }

# check ok|deny <роль> <описание> <SQL> [подготовка от суперпользователя] [ожидаемый текст ошибки]
check() {
    local expect=$1 role=$2 desc=$3 sql=$4 setup=${5:-} pattern=${6:-permission denied}
    local out rc
    out=$(printf 'BEGIN;\n%s\nSET LOCAL ROLE %s;\n%s;\nROLLBACK;\n' "$setup" "$role" "$sql" | psql_admin 2>&1)
    rc=$?
    if [[ $expect == ok && $rc -eq 0 ]] || [[ $expect == deny && $rc -ne 0 && $out == *"$pattern"* ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'ПРОВАЛ  [%s] %s: %s\n        SQL: %s\n        вывод: %s\n' "$expect" "$role" "$desc" "$sql" "$out"
    fi
}

DOC="00000000-0000-0000-0000-0000000000d1"
CHUNK="00000000-0000-0000-0000-0000000000c1"
FX_DOC="INSERT INTO library.documents (id, title, category, source_type, content_type) VALUES ('$DOC', 't', 'c', 's', 'text/plain');"
FX_CHUNK="$FX_DOC INSERT INTO library.chunks (id, document_id, chunk_index, text) VALUES ('$CHUNK', '$DOC', 0, 'x');"
VEC="(SELECT array_agg(0.1)::vector FROM generate_series(1, 1024))"

# --- Ни одна роль сервиса не суперпользователь и не владелец -------------------------------------
n=$(psql_admin -c "SELECT count(*) FROM pg_roles WHERE rolname IN ('$AUTH','$CHAT','$LIB','$ING','$GRAPH','$DBS') AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolbypassrls)")
if [[ $n == 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  у ролей сервисов есть привилегированные атрибуты"; fi

n=$(psql_admin -c "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_roles r ON r.oid=c.relowner WHERE n.nspname IN ('core','auth','chat','library','graph','rag','audit') AND r.rolname <> 'app_owner' AND c.relkind IN ('r','p','v','m','S')")
if [[ $n == 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  объекты управляемых схем принадлежат не app_owner ($n)"; fi

n=$(psql_admin -c "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_roles r ON r.oid=p.proowner WHERE n.nspname IN ('core','auth','chat','library','graph','rag','audit') AND r.rolname <> 'app_owner'")
if [[ $n == 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  функции управляемых схем принадлежат не app_owner ($n)"; fi

# --- auth-svc ------------------------------------------------------------------------------------
check ok   "$AUTH" "читает и пишет auth"            "UPDATE auth.users SET updated_at = now()"
check ok   "$AUTH" "читает справочники core"         "SELECT count(*) FROM core.universities"
check deny "$AUTH" "не пишет в core"                 "DELETE FROM core.universities"
check deny "$AUTH" "не видит chat"                   "SELECT count(*) FROM chat.chat_messages"
check deny "$AUTH" "не видит library"                "SELECT count(*) FROM library.documents"
check deny "$AUTH" "не создаёт таблицы"              "CREATE TABLE auth.evil (x int)"

# --- chat-svc ------------------------------------------------------------------------------------
check ok   "$CHAT" "пишет сессии, FK на auth.users проверяется без доступа к auth" \
      "INSERT INTO chat.chat_sessions (user_id) SELECT '00000000-0000-0000-0000-000000000000'::uuid WHERE false; INSERT INTO chat.chat_sessions (user_id) VALUES (NULL)"
check deny "$CHAT" "не видит auth.users"             "SELECT * FROM auth.users"
check deny "$CHAT" "не видит rag"                    "SELECT * FROM rag.retrieval_runs"
check deny "$CHAT" "не видит library"                "SELECT * FROM library.documents"

# --- library-svc: только чтение --------------------------------------------------------------------
check ok   "$LIB" "читает документы"                 "SELECT count(*) FROM library.documents"
check ok   "$LIB" "читает файлы и связи"             "SELECT count(*) FROM library.document_files, library.document_relations"
check deny "$LIB" "не правит документы"              "UPDATE library.documents SET title = 'x'"
check deny "$LIB" "не удаляет документы"             "DELETE FROM library.documents"
check deny "$LIB" "не создаёт темы"                  "INSERT INTO library.topics (name, slug) VALUES ('x', 'x')"
check deny "$LIB" "не читает чанки"                  "SELECT count(*) FROM library.chunks"
check deny "$LIB" "не видит auth"                    "SELECT count(*) FROM auth.users"

# --- ingest-worker -------------------------------------------------------------------------------
check ok   "$ING" "берёт документ из очереди"        "SELECT id FROM library.documents WHERE ingest_status = 'pending' FOR UPDATE SKIP LOCKED" "$FX_DOC"
check ok   "$ING" "двигает статус очереди"           "UPDATE library.documents SET ingest_status='processing', ingest_attempts=1, ingest_started_at=now(), ingest_error=NULL, ingest_next_attempt_at=NULL, indexed_at=now() WHERE id='$DOC'" "$FX_DOC"
check ok   "$ING" "пишет чанк и эмбеддинг"          "INSERT INTO library.chunks (document_id, chunk_index, text) VALUES ('$DOC', 1, 'y') RETURNING id" "$FX_DOC"
check ok   "$ING" "пересоздаёт чанки"                "DELETE FROM library.chunks WHERE document_id='$DOC'" "$FX_CHUNK"
check ok   "$ING" "пишет эмбеддинг"                  "INSERT INTO library.chunk_embeddings (chunk_id, embedding, embedding_model) SELECT '$CHUNK', $VEC, 'm'" "$FX_CHUNK"
check ok   "$ING" "читает размерность вектора"       "SELECT core.vector_column_dimension('library.chunk_embeddings', 'embedding')"
check deny "$ING" "не меняет заголовок документа"    "UPDATE library.documents SET title = 'x' WHERE id='$DOC'" "$FX_DOC"
check deny "$ING" "не создаёт документы"             "INSERT INTO library.documents (title, category, source_type, content_type) VALUES ('a','b','c','d')"
check deny "$ING" "не удаляет документы"             "DELETE FROM library.documents WHERE id='$DOC'" "$FX_DOC"
check deny "$ING" "не правит чанки"                  "UPDATE library.chunks SET text='z'" "$FX_CHUNK"
check deny "$ING" "не видит auth"                    "SELECT count(*) FROM auth.users"
check deny "$ING" "не видит graph"                   "SELECT count(*) FROM graph.entities"

# --- graph-rag-svc ---------------------------------------------------------------------------------
check ok   "$GRAPH" "читает библиотеку"              "SELECT count(*) FROM library.chunks, library.documents, library.chunk_embeddings, library.document_files"
check ok   "$GRAPH" "пишет граф"                     "INSERT INTO graph.entities (entity_type, canonical_name) VALUES ('t', 'n')"
check ok   "$GRAPH" "пишет аналитику rag"            "INSERT INTO rag.retrieval_runs (request_id, question) VALUES ('r', 'q')"
check deny "$GRAPH" "не правит аналитику rag"        "UPDATE rag.retrieval_runs SET status = 'x'"
check deny "$GRAPH" "не пишет в library"             "DELETE FROM library.chunks"
check deny "$GRAPH" "не видит chat"                  "SELECT count(*) FROM chat.chat_messages"
check deny "$GRAPH" "не видит auth"                  "SELECT count(*) FROM auth.users"

# --- db-svc ----------------------------------------------------------------------------------------
check ok   "$DBS" "читает пользователей без хеша"   "SELECT id, email, role, is_active FROM auth.users"
check deny "$DBS" "не читает password_hash"          "SELECT password_hash FROM auth.users"
check deny "$DBS" "SELECT * по auth.users недоступен" "SELECT * FROM auth.users"
check ok   "$DBS" "меняет роль пользователя"         "UPDATE auth.users SET role = 'curator' WHERE email = 'nobody'"
check deny "$DBS" "не меняет password_hash"          "UPDATE auth.users SET password_hash = 'x'"
check deny "$DBS" "не создаёт пользователей"         "INSERT INTO auth.users (email, password_hash) VALUES ('a@b.c', 'x')"
check ok   "$DBS" "считает зависимости пользователя" "SELECT count(*) FROM auth.refresh_tokens WHERE user_id IS NOT NULL"
check deny "$DBS" "не читает token_hash"             "SELECT token_hash FROM auth.refresh_tokens"
check deny "$DBS" "не читает токены писем"           "SELECT token_hash FROM auth.password_resets"
check deny "$DBS" "не пишет токены"                  "DELETE FROM auth.refresh_tokens"
check ok   "$DBS" "правит core"                      "INSERT INTO core.universities (name) VALUES ('x')"
check ok   "$DBS" "правит library"                   "INSERT INTO library.topics (name, slug) VALUES ('x', 'x')"
check ok   "$DBS" "пишет задачи импорта"             "INSERT INTO public.dbsvc_jobs (id, job_type, status) VALUES (gen_random_uuid(), 't', 'queued')"
check ok   "$DBS" "очищает листовую таблицу (CSV replace)" "TRUNCATE library.document_relations"
check deny "$DBS" "не очищает граф"                  "TRUNCATE graph.entities"
check deny "$DBS" "не очищает auth"                  "TRUNCATE auth.user_profiles"
check ok   "$DBS" "читает граф"                      "SELECT count(*) FROM graph.entities"
check deny "$DBS" "не пишет граф напрямую"           "INSERT INTO graph.entities (entity_type, canonical_name) VALUES ('t', 'n')"
check ok   "$DBS" "читает чаты"                      "SELECT count(*) FROM chat.chat_messages"
check deny "$DBS" "не пишет чаты"                    "DELETE FROM chat.chat_messages"
check ok   "$DBS" "добавляет запись в журнал"        "INSERT INTO audit.db_actions (actor_type, action) VALUES ('token', 'test')"
check ok   "$DBS" "читает журнал"                    "SELECT count(*) FROM audit.db_actions"
check deny "$DBS" "не правит журнал"                 "UPDATE audit.db_actions SET action = 'x'"
check deny "$DBS" "не удаляет из журнала"            "DELETE FROM audit.db_actions"
check deny "$DBS" "не обнуляет журнал"               "TRUNCATE audit.db_actions"
check deny "$DBS" "не создаёт таблицы в public"      "CREATE TABLE public.evil (x int)"
check deny "$DBS" "не создаёт схемы"                 "CREATE SCHEMA evil"
check deny "$DBS" "не удаляет таблицы"               "DROP TABLE library.documents" "" "must be owner"
check deny "$DBS" "не создаёт роли"                  "CREATE ROLE evil"

# --- журнал неизменяем даже для владельца, пока не отключён триггер --------------------------------
check deny app_owner "владелец не стирает журнал"    "DELETE FROM audit.db_actions" \
      "INSERT INTO audit.db_actions (actor_type, action) VALUES ('token', 'seed');" "допускает только добавление"

# --- будущие таблицы владельца получают права по группам --------------------------------------------
check ok   app_owner "владелец создаёт таблицу" "CREATE TABLE core.tmp_probe (x int); GRANT SELECT ON core.tmp_probe TO PUBLIC"
out=$(printf 'BEGIN;\nSET LOCAL ROLE app_owner;\nCREATE TABLE core.tmp_probe (x int);\nRESET ROLE;\nSET LOCAL ROLE %s;\nSELECT count(*) FROM core.tmp_probe;\nROLLBACK;\n' "$AUTH" | psql_admin 2>&1)
if [[ $? -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  default privileges: новая таблица core недоступна чтению: $out"; fi
out=$(printf 'BEGIN;\nSET LOCAL ROLE app_owner;\nCREATE TABLE library.tmp_probe (x int);\nRESET ROLE;\nSET LOCAL ROLE %s;\nSELECT count(*) FROM library.tmp_probe;\nROLLBACK;\n' "$LIB" | psql_admin 2>&1)
if [[ $? -ne 0 && $out == *"permission denied"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  default privileges: новая таблица library открыта library-svc без явной выдачи: $out"; fi

# --- реальные подключения по паролю ------------------------------------------------------------------
# На loopback pg_hba официального образа стоит trust, и пароль там не проверяется, поэтому
# подключаемся по адресу контейнера в сети, как это делают сервисы.
HOST=$(docker exec "$C" hostname -i | awk '{print $1}')
connect() { # роль, переменная с паролем
    docker exec -e PGPASSWORD="$(docker exec "$C" printenv "$2")" "$C" \
        psql -h "$HOST" -U "$1" -d "$DB" -At -c 'SELECT current_user' 2>&1
}
for pair in "$AUTH:AUTH_DB_PASSWORD" "$CHAT:CHAT_DB_PASSWORD" "$LIB:LIBRARY_DB_PASSWORD" \
            "$ING:INGEST_DB_PASSWORD" "$GRAPH:GRAPH_DB_PASSWORD" "$DBS:DBSVC_DB_PASSWORD"; do
    r=${pair%%:*}; v=${pair##*:}
    if [[ $(connect "$r" "$v") == "$r" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  $r не подключается с паролем из $v"; fi
done
out=$(docker exec -e PGPASSWORD=wrong "$C" psql -h "$HOST" -U "$AUTH" -d "$DB" -c 'SELECT 1' 2>&1)
if [[ $out == *"authentication failed"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  неверный пароль принят: $out"; fi
out=$(docker exec -e PGPASSWORD=x "$C" psql -h "$HOST" -U app_owner -d "$DB" -c 'SELECT 1' 2>&1)
if [[ $out == *"not permitted to log in"* || $out == *"authentication failed"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  app_owner может войти: $out"; fi

printf '\nИтого: %d проверок пройдено, %d провалено\n' "$pass" "$fail"
exit "$fail"
