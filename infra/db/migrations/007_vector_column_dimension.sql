-- =============================================================
-- 007_vector_column_dimension.sql
-- core.vector_column_dimension(): размерность pgvector-колонки, объявленная в схеме БД.
--
-- Раньше ingest-worker и graph-rag-svc каждый содержали собственную копию запроса к
-- pg_attribute с разбором format_type() и успели разойтись (в одной копии был SQL, который
-- вообще не выполнялся). Сервисы лежат в разных репозиториях и собираются из своих
-- контекстов, общего Python-модуля у них быть не может, поэтому логика живёт там, где
-- живёт сама схема, — в БД, и оба сервиса просто вызывают эту функцию.
--
-- Возвращает NULL, если таблицы или колонки нет либо тип объявлен без размерности.
--
-- init.sql делает то же самое на пустом volume; этот файл — для уже поднятых баз.
-- Повторный запуск безопасен (CREATE OR REPLACE).
--
--   psql "$POSTGRES_ADMIN_URL" -f 007_vector_column_dimension.sql
-- =============================================================

\set ON_ERROR_STOP on

CREATE OR REPLACE FUNCTION core.vector_column_dimension(schema_table text, col text)
RETURNS integer
LANGUAGE sql
STABLE
AS $$
    -- to_regclass(), а не ::regclass: для несуществующей таблицы он вернёт NULL, а приведение
    -- бросило бы исключение. attisdropped отсекает удалённые колонки.
    SELECT substring(format_type(atttypid, atttypmod) FROM '\((\d+)\)')::integer
    FROM pg_attribute
    WHERE attrelid = to_regclass(schema_table)
      AND attname = col
      AND NOT attisdropped
$$;

COMMENT ON FUNCTION core.vector_column_dimension(text, text) IS
    'Размерность pgvector-колонки из схемы БД (NULL — колонки нет или тип без размера). Единственная реализация для ingest-worker и graph-rag-svc.';
