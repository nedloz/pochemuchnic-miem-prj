-- =============================================================
-- roles/monitoring.sql
-- Роль для postgres_exporter (docker-compose.observability.yml): LOGIN, только метрики сервера
-- (членство в pg_monitor), без доступа к данным приложения. Подключается в конце create_roles.sql,
-- поэтому работает и при инициализации, и через sync.sql.
--
-- Опциональна: роль создаётся, если задан MONITORING_DB_PASSWORD (режим password) либо
-- MONITORING_DB_AUTH=cert. Иначе скрипт ничего не делает, и стек без наблюдаемости не меняется.
-- Переменные: MONITORING_DB_USER (monitoring_user), MONITORING_DB_PASSWORD, MONITORING_DB_AUTH
-- (password | cert, как у остальных ролей, см. vars.sql).
-- =============================================================

\getenv monitoring_user MONITORING_DB_USER
\if :{?monitoring_user} \else \set monitoring_user monitoring_user \endif
\getenv monitoring_pass MONITORING_DB_PASSWORD
\if :{?monitoring_pass} \else \set monitoring_pass '' \endif
\getenv monitoring_mode MONITORING_DB_AUTH
\if :{?monitoring_mode} \else \set monitoring_mode password \endif

SELECT (:'monitoring_mode' NOT IN ('password', 'cert')) AS monitoring_bad_mode \gset
\if :monitoring_bad_mode
DO $$ BEGIN
    RAISE EXCEPTION 'Способ входа роли мониторинга должен быть password или cert (MONITORING_DB_AUTH).';
END $$;
\endif

SELECT (:'monitoring_pass' <> '' OR :'monitoring_mode' = 'cert') AS monitoring_enabled \gset
\if :monitoring_enabled

SELECT format('CREATE ROLE %I LOGIN', :'monitoring_user')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'monitoring_user')
\gexec

SELECT format(
    'ALTER ROLE %I WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT '
    'CONNECTION LIMIT 3 %s',
    :'monitoring_user',
    CASE WHEN :'monitoring_mode' = 'cert' THEN 'PASSWORD NULL' ELSE format('PASSWORD %L', :'monitoring_pass') END)
\gexec

SELECT format('REVOKE %I FROM %I', CASE WHEN :'monitoring_mode' = 'cert' THEN 'pw_login' ELSE 'pki_login' END,
              :'monitoring_user')
WHERE EXISTS (SELECT 1 FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid JOIN pg_roles u ON u.oid = m.member
              WHERE r.rolname = CASE WHEN :'monitoring_mode' = 'cert' THEN 'pw_login' ELSE 'pki_login' END
                AND u.rolname = :'monitoring_user')
\gexec
SELECT format('GRANT %I TO %I', CASE WHEN :'monitoring_mode' = 'cert' THEN 'pki_login' ELSE 'pw_login' END,
              :'monitoring_user') \gexec

GRANT pg_monitor TO :"monitoring_user";
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'monitoring_user') \gexec

\endif
