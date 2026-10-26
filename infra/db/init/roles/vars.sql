-- =============================================================
-- roles/vars.sql
-- Имена LOGIN-ролей сервисов и их пароли берутся из окружения контейнера postgres
-- (compose пробрасывает их из корневого .env) через \getenv, а не зашиты в SQL:
-- раньше пароли ролей лежали литералами в init.sql, а .env их только дублировал, поэтому
-- смена пароля в .env тихо расходилась с тем, что стояло в базе.
--
-- Подключается из create_roles.sql и grants.sql. Нужен psql 15+ (\getenv).
-- =============================================================

\set ON_ERROR_STOP on

-- Имя роли берётся из <ENV>, а если переменная не задана — из значения по умолчанию.
\getenv auth_user    AUTH_DB_USER
\if :{?auth_user}    \else \set auth_user    auth_user    \endif
\getenv chat_user    CHAT_DB_USER
\if :{?chat_user}    \else \set chat_user    chat_user    \endif
\getenv library_user LIBRARY_DB_USER
\if :{?library_user} \else \set library_user library_user \endif
\getenv ingest_user  INGEST_DB_USER
\if :{?ingest_user}  \else \set ingest_user  ingest_user  \endif
\getenv graph_user   GRAPH_DB_USER
\if :{?graph_user}   \else \set graph_user   graph_user   \endif
\getenv dbsvc_user   DBSVC_DB_USER
\if :{?dbsvc_user}   \else \set dbsvc_user   dbsvc_user   \endif

-- Пароли значений по умолчанию не имеют. Они нужны только create_roles.sql, но читаются
-- здесь, чтобы все проверки были в одном месте.
\getenv auth_pass    AUTH_DB_PASSWORD
\getenv chat_pass    CHAT_DB_PASSWORD
\getenv library_pass LIBRARY_DB_PASSWORD
\getenv ingest_pass  INGEST_DB_PASSWORD
\getenv graph_pass   GRAPH_DB_PASSWORD
\getenv dbsvc_pass   DBSVC_DB_PASSWORD

-- Роли-владельцы и группы фиксированы: от их имён зависят права, а настраивать тут нечего.
\set owner_role app_owner
