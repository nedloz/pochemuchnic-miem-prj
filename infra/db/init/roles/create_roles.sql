-- =============================================================
-- roles/create_roles.sql
-- Создаёт роли и синхронизирует атрибуты и пароли LOGIN-ролей. Идемпотентен: безопасно
-- запускать на уже существующей базе, чтобы привести пароли в соответствие с .env.
--
-- Модель ролей (подробности — infra/db/README.md):
--   app_owner            NOLOGIN, владелец схем и объектов. Под ним выполняются DDL и миграции
--                        (SET ROLE app_owner); подключиться им нельзя.
--   <схема>_ro/_rw       NOLOGIN, группы прав на схему: чтение / чтение и запись.
--   <сервис>_user        LOGIN, по одной на процесс; получают права членством в группах
--                        и точечными GRANT (см. grants.sql). Не суперпользователи, без DDL.
--   POSTGRES_ADMIN_USER  суперпользователь контейнера. Нужен только инициализации, миграциям
--                        и оператору; ни один сервис под ним не подключается.
-- =============================================================

\i /docker-entrypoint-initdb.d/roles/vars.sql

-- Все шесть паролей обязательны. Без этой проверки отсутствующая переменная превратилась бы
-- в непонятную синтаксическую ошибку, а пустой пароль — в роль без пароля.
\if :{?auth_pass} \else \set auth_pass '' \endif
\if :{?chat_pass} \else \set chat_pass '' \endif
\if :{?library_pass} \else \set library_pass '' \endif
\if :{?ingest_pass} \else \set ingest_pass '' \endif
\if :{?graph_pass} \else \set graph_pass '' \endif
\if :{?dbsvc_pass} \else \set dbsvc_pass '' \endif

SELECT (:'auth_pass' = '' OR :'chat_pass' = '' OR :'library_pass' = ''
        OR :'ingest_pass' = '' OR :'graph_pass' = '' OR :'dbsvc_pass' = '') AS has_empty_pass \gset
\if :has_empty_pass
DO $$ BEGIN
    RAISE EXCEPTION 'Не заданы пароли ролей. Нужны непустые AUTH_DB_PASSWORD, CHAT_DB_PASSWORD, '
                    'LIBRARY_DB_PASSWORD, INGEST_DB_PASSWORD, GRAPH_DB_PASSWORD, DBSVC_DB_PASSWORD '
                    'в окружении контейнера postgres (корневой .env).';
END $$;
\endif

-- Роль сервиса не должна совпадать с суперпользователем контейнера: ниже у неё снимаются
-- права суперпользователя, и это сломало бы саму базу.
SELECT (current_user IN (:'auth_user', :'chat_user', :'library_user', :'ingest_user',
                         :'graph_user', :'dbsvc_user')) AS clashes_with_admin \gset
\if :clashes_with_admin
DO $$ BEGIN
    RAISE EXCEPTION 'Имя роли сервиса совпадает с POSTGRES_ADMIN_USER (%). Для сервисов нужны '
                    'отдельные непривилегированные роли.', current_user;
END $$;
\endif

-- Группы и владелец: NOLOGIN, без пароля.
SELECT format('CREATE ROLE %I NOLOGIN', r)
FROM unnest(ARRAY[
    'app_owner',
    'core_ro', 'core_rw', 'auth_ro', 'auth_rw', 'chat_ro', 'chat_rw',
    'library_ro', 'library_rw', 'graph_ro', 'graph_rw', 'rag_ro', 'rag_rw'
]) AS r
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r)
\gexec

-- Роли сервисов: создать, если нет, и в любом случае привести атрибуты и пароль к желаемым.
-- CONNECTION LIMIT не даёт одному зависшему или скомпрометированному сервису выбрать все
-- соединения (max_connections по умолчанию 100) и оставить остальных без базы.
SELECT format('CREATE ROLE %I LOGIN', v.name)
FROM (VALUES (:'auth_user'), (:'chat_user'), (:'library_user'),
             (:'ingest_user'), (:'graph_user'), (:'dbsvc_user')) AS v(name)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v.name)
\gexec

SELECT format(
    'ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT '
    'CONNECTION LIMIT %s PASSWORD %L',
    v.name, v.conn_limit, v.pass)
FROM (VALUES
    (:'auth_user',    20, :'auth_pass'),
    (:'chat_user',    30, :'chat_pass'),
    (:'library_user', 20, :'library_pass'),
    (:'ingest_user',  10, :'ingest_pass'),
    (:'graph_user',   30, :'graph_pass'),
    (:'dbsvc_user',   40, :'dbsvc_pass')
) AS v(name, conn_limit, pass)
\gexec

-- Группы и владелец входить в базу не могут и ничем, кроме прав, не обладают.
SELECT format('ALTER ROLE %I NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOLOGIN', r)
FROM unnest(ARRAY[
    'app_owner',
    'core_ro', 'core_rw', 'auth_ro', 'auth_rw', 'chat_ro', 'chat_rw',
    'library_ro', 'library_rw', 'graph_ro', 'graph_rw', 'rag_ro', 'rag_rw'
]) AS r
\gexec

-- Доступ к базе: PUBLIC по умолчанию может подключаться и создавать временные таблицы.
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', current_database()) \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), v.name)
FROM (VALUES (:'auth_user'), (:'chat_user'), (:'library_user'),
             (:'ingest_user'), (:'graph_user'), (:'dbsvc_user')) AS v(name)
\gexec
-- app_owner создаёт схемы, поэтому ему нужно CREATE на базе. Подключиться он не может.
SELECT format('GRANT CONNECT, CREATE ON DATABASE %I TO app_owner', current_database()) \gexec
-- В PostgreSQL 16 создавать объекты в public может только владелец базы. Служебная таблица
-- db-svc (public.dbsvc_jobs) принадлежит app_owner, поэтому ему это право выдаётся явно.
GRANT USAGE, CREATE ON SCHEMA public TO app_owner;

-- search_path: library-svc обращается к таблицам без указания схемы, остальным он
-- облегчает неквалифицированные запросы. Значения прежние, добавлены ingest и dbsvc.
SELECT format('ALTER ROLE %I SET search_path = %s', v.name, v.path)
FROM (VALUES
    (:'auth_user',    'auth, core, public'),
    (:'chat_user',    'chat, core, public'),
    (:'library_user', 'library, core, public'),
    (:'ingest_user',  'library, core, public'),
    (:'graph_user',   'graph, library, core, public'),
    (:'dbsvc_user',   'core, auth, library, chat, graph, public')
) AS v(name, path)
\gexec
