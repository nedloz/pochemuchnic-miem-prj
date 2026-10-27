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

-- Режим входа — password или cert. Опечатка («certs», «Cert») молча оставила бы роль с
-- паролем, хотя оператор рассчитывал на вход по сертификату.
SELECT EXISTS (
    SELECT 1
    FROM (VALUES (:'auth_mode'), (:'chat_mode'), (:'library_mode'), (:'ingest_mode'),
                 (:'graph_mode'), (:'dbsvc_mode')) AS v(mode)
    WHERE v.mode NOT IN ('password', 'cert')
) AS bad_mode \gset
\if :bad_mode
DO $$ BEGIN
    RAISE EXCEPTION 'Способ входа роли должен быть password или cert (переменные *_DB_AUTH).';
END $$;
\endif

-- Пароль обязателен у ролей в режиме password. Без этой проверки отсутствующая переменная
-- превратилась бы в непонятную синтаксическую ошибку, а пустой пароль — в роль без пароля.
\if :{?auth_pass} \else \set auth_pass '' \endif
\if :{?chat_pass} \else \set chat_pass '' \endif
\if :{?library_pass} \else \set library_pass '' \endif
\if :{?ingest_pass} \else \set ingest_pass '' \endif
\if :{?graph_pass} \else \set graph_pass '' \endif
\if :{?dbsvc_pass} \else \set dbsvc_pass '' \endif

SELECT EXISTS (
    SELECT 1
    FROM (VALUES (:'auth_mode', :'auth_pass'), (:'chat_mode', :'chat_pass'),
                 (:'library_mode', :'library_pass'), (:'ingest_mode', :'ingest_pass'),
                 (:'graph_mode', :'graph_pass'), (:'dbsvc_mode', :'dbsvc_pass')) AS v(mode, pass)
    WHERE v.mode = 'password' AND v.pass = ''
) AS has_empty_pass \gset
\if :has_empty_pass
DO $$ BEGIN
    RAISE EXCEPTION 'Не заданы пароли ролей в режиме password. Нужны непустые *_DB_PASSWORD '
                    '(AUTH, CHAT, LIBRARY, INGEST, GRAPH, DBSVC) в окружении контейнера postgres '
                    '(корневой .env) либо режим cert для этой роли (*_DB_AUTH=cert).';
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
    'library_ro', 'library_rw', 'graph_ro', 'graph_rw', 'rag_ro', 'rag_rw',
    'pki_login', 'pw_login'
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

-- В режиме cert пароль снимается совсем (PASSWORD NULL): вход по паролю становится невозможен
-- не только по правилам pg_hba, но и по самой роли.
SELECT format(
    'ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT '
    'CONNECTION LIMIT %s %s',
    v.name, v.conn_limit,
    CASE WHEN v.mode = 'cert' THEN 'PASSWORD NULL' ELSE format('PASSWORD %L', v.pass) END)
FROM (VALUES
    (:'auth_user',    20, :'auth_mode',    :'auth_pass'),
    (:'chat_user',    30, :'chat_mode',    :'chat_pass'),
    (:'library_user', 20, :'library_mode', :'library_pass'),
    (:'ingest_user',  10, :'ingest_mode',  :'ingest_pass'),
    (:'graph_user',   30, :'graph_mode',   :'graph_pass'),
    (:'dbsvc_user',   40, :'dbsvc_mode',   :'dbsvc_pass')
) AS v(name, conn_limit, mode, pass)
\gexec

-- Способ входа для pg_hba (infra/db/pg_hba.pki.conf выбирает правило по членству в группе).
SELECT format('REVOKE %I FROM %I', g.stale, v.name)
FROM (VALUES
    (:'auth_user', :'auth_mode'), (:'chat_user', :'chat_mode'), (:'library_user', :'library_mode'),
    (:'ingest_user', :'ingest_mode'), (:'graph_user', :'graph_mode'), (:'dbsvc_user', :'dbsvc_mode')
) AS v(name, mode)
CROSS JOIN LATERAL (SELECT CASE WHEN v.mode = 'cert' THEN 'pw_login' ELSE 'pki_login' END AS stale) g
WHERE EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid JOIN pg_roles u ON u.oid = m.member
              WHERE r.rolname = g.stale AND u.rolname = v.name)
\gexec

SELECT format('GRANT %I TO %I', CASE WHEN v.mode = 'cert' THEN 'pki_login' ELSE 'pw_login' END, v.name)
FROM (VALUES
    (:'auth_user', :'auth_mode'), (:'chat_user', :'chat_mode'), (:'library_user', :'library_mode'),
    (:'ingest_user', :'ingest_mode'), (:'graph_user', :'graph_mode'), (:'dbsvc_user', :'dbsvc_mode')
) AS v(name, mode)
\gexec

-- Группы и владелец входить в базу не могут и ничем, кроме прав, не обладают.
SELECT format('ALTER ROLE %I NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS NOLOGIN', r)
FROM unnest(ARRAY[
    'app_owner',
    'core_ro', 'core_rw', 'auth_ro', 'auth_rw', 'chat_ro', 'chat_rw',
    'library_ro', 'library_rw', 'graph_ro', 'graph_rw', 'rag_ro', 'rag_rw',
    'pki_login', 'pw_login'
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

-- Роль для postgres_exporter (опциональна, см. monitoring.sql).
\i /docker-entrypoint-initdb.d/roles/monitoring.sql
