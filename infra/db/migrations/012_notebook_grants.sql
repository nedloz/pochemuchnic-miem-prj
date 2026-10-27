-- =============================================================
-- 012_notebook_grants.sql
-- Права ingest_user на быстрые ответы и ссылки для уже поднятых баз (продолжение 011).
-- На пустом томе то же самое делает init.sql через roles/grants.sql; держать в синхроне.
--
-- Что получает ingest_user (имя роли берётся из INGEST_DB_USER окружения контейнера postgres,
-- как в 008):
--   * SELECT на library.quick_answer_variants, library.links и library.quick_answers
--     (is_active варианта лежит в родительском быстром ответе);
--   * UPDATE только колонок embedding и embedding_model у variants и links.
-- Вставлять, удалять и менять тексты воркер не может.
--
-- Файл ничего не создаёт сам: он перезапускает roles/grants.sql, единственное место с правами
-- всех ролей (идемпотентен, сначала снимает права, потом выдаёт заново; как в 008).
--
-- Запуск (скрипт читает roles/*.sql из каталога init, смонтированного в контейнер):
--   docker compose exec -T postgres psql -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
--       -v ON_ERROR_STOP=1 < infra/db/migrations/012_notebook_grants.sql
--
-- Повторный запуск безопасен. Требует миграции 011 (таблицы quick_answers, quick_answer_variants, links).
-- =============================================================

\set ON_ERROR_STOP on

SELECT to_regclass('library.quick_answers') IS NULL
    OR to_regclass('library.quick_answer_variants') IS NULL
    OR to_regclass('library.links') IS NULL AS missing_prerequisites \gset
\if :missing_prerequisites
DO $$ BEGIN
    RAISE EXCEPTION 'Сначала примените миграцию 011_notebook_pipeline.sql.';
END $$;
\endif

\i /docker-entrypoint-initdb.d/roles/grants.sql
