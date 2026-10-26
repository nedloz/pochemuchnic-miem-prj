-- =============================================================
-- 008_roles_and_audit.sql
-- Переход на новую модель ролей и журнал действий администратора для уже поднятых баз
-- (задача IVHR-18). На пустом томе то же самое делает init.sql; держать в синхроне.
--
-- Что делает:
--   1. Создаёт роли (roles/create_roles.sql): app_owner, группы <схема>_ro/_rw, роли сервисов
--      ingest_user и dbsvc_user; приводит пароли и атрибуты всех LOGIN-ролей к значениям из
--      окружения контейнера postgres.
--   2. Передаёт app_owner владение схемами и объектами core, auth, chat, library, graph, rag
--      и public.dbsvc_jobs. Прежний владелец (суперпользователь контейнера) больше не нужен
--      ни одному сервису.
--   3. Создаёт public.dbsvc_jobs (если нет) и audit.db_actions.
--   4. Пересобирает права (roles/grants.sql).
--
-- ПЕРЕД ЗАПУСКОМ:
--   * в корневом .env должны быть INGEST_DB_USER/INGEST_DB_PASSWORD и
--     DBSVC_DB_USER/DBSVC_DB_PASSWORD, а postgres должен быть пересоздан с новым окружением
--     (docker compose up -d postgres), иначе скрипт остановится на проверке паролей;
--   * сервисы лучше остановить: у них отзываются широкие права, а ingest-worker и db-svc
--     переключаются на новые роли.
--
-- Запуск (скрипт читает roles/*.sql из каталога init, смонтированного в контейнер):
--   docker compose exec -T postgres psql -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
--       -v ON_ERROR_STOP=1 < infra/db/migrations/008_roles_and_audit.sql
--
-- Повторный запуск безопасен. Новые миграции выполняйте так, чтобы объекты принадлежали
-- app_owner: первой строкой `SET ROLE app_owner;`, а в конце `RESET ROLE;`.
-- =============================================================

\set ON_ERROR_STOP on

\i /docker-entrypoint-initdb.d/roles/create_roles.sql

-- 2) Владение. Последовательности, привязанные к колонкам, и индексы переходят вместе с
--    таблицей, поэтому отдельно меняется только то, что не связано ни с чем.
DO $own$
DECLARE
    schemas constant text[] := ARRAY['core', 'auth', 'chat', 'library', 'graph', 'rag'];
    s text;
    rec record;
    leftovers int;
BEGIN
    FOREACH s IN ARRAY schemas LOOP
        IF to_regnamespace(s) IS NOT NULL THEN
            EXECUTE format('ALTER SCHEMA %I OWNER TO app_owner', s);
        END IF;
    END LOOP;

    FOR rec IN
        SELECT n.nspname, c.relname, c.relkind
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE (n.nspname = ANY (schemas) OR (n.nspname = 'public' AND c.relname = 'dbsvc_jobs'))
          AND c.relowner <> 'app_owner'::regrole
          AND c.relkind IN ('r', 'p', 'v', 'm', 'f')
    LOOP
        EXECUTE format('ALTER %s %I.%I OWNER TO app_owner',
            CASE rec.relkind
                WHEN 'v' THEN 'VIEW'
                WHEN 'm' THEN 'MATERIALIZED VIEW'
                WHEN 'f' THEN 'FOREIGN TABLE'
                ELSE 'TABLE'
            END, rec.nspname, rec.relname);
    END LOOP;

    FOR rec IN
        SELECT n.nspname, c.relname
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = ANY (schemas)
          AND c.relkind = 'S'
          AND c.relowner <> 'app_owner'::regrole
          AND NOT EXISTS (
              SELECT 1 FROM pg_depend d
              WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype IN ('a', 'i')
          )
    LOOP
        EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO app_owner', rec.nspname, rec.relname);
    END LOOP;

    FOR rec IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = ANY (schemas) AND p.proowner <> 'app_owner'::regrole
    LOOP
        EXECUTE format('ALTER FUNCTION %s OWNER TO app_owner', rec.sig);
    END LOOP;

    SELECT count(*) INTO leftovers
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = ANY (schemas) AND c.relowner <> 'app_owner'::regrole
      AND c.relkind IN ('r', 'p', 'v', 'm', 'f', 'S');
    IF leftovers > 0 THEN
        RAISE EXCEPTION 'После передачи владения у app_owner не оказалось % объектов', leftovers;
    END IF;
END
$own$;

-- 3) Служебные объекты db-svc.
SET ROLE app_owner;

CREATE TABLE IF NOT EXISTS public.dbsvc_jobs (
    id UUID PRIMARY KEY,
    job_type TEXT NOT NULL,
    status TEXT NOT NULL,
    stage TEXT,
    message TEXT,
    progress_current INTEGER NOT NULL DEFAULT 0,
    progress_total INTEGER NOT NULL DEFAULT 0,
    cancel_requested BOOLEAN NOT NULL DEFAULT FALSE,
    payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    result JSONB,
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ
);

CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE IF NOT EXISTS audit.db_actions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_type TEXT NOT NULL CHECK (actor_type IN ('user', 'token', 'anonymous')),
    actor_user_id UUID,
    actor_role TEXT,
    client_ip TEXT,
    action TEXT NOT NULL,
    success BOOLEAN NOT NULL DEFAULT TRUE,
    target_schema TEXT,
    target_table TEXT,
    target_pk TEXT,
    object_key TEXT,
    details JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS idx_db_actions_occurred_at ON audit.db_actions(occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_db_actions_actor ON audit.db_actions(actor_user_id);
CREATE INDEX IF NOT EXISTS idx_db_actions_target ON audit.db_actions(target_schema, target_table);

CREATE OR REPLACE FUNCTION audit.forbid_change()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit.db_actions допускает только добавление записей';
END;
$$;

DROP TRIGGER IF EXISTS trg_db_actions_immutable ON audit.db_actions;
CREATE TRIGGER trg_db_actions_immutable
    BEFORE UPDATE OR DELETE ON audit.db_actions
    FOR EACH ROW EXECUTE FUNCTION audit.forbid_change();

DROP TRIGGER IF EXISTS trg_db_actions_no_truncate ON audit.db_actions;
CREATE TRIGGER trg_db_actions_no_truncate
    BEFORE TRUNCATE ON audit.db_actions
    FOR EACH STATEMENT EXECUTE FUNCTION audit.forbid_change();

RESET ROLE;

-- 4) Права.
\i /docker-entrypoint-initdb.d/roles/grants.sql
