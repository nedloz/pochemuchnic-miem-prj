-- =============================================================
-- roles/sync.sql
-- Приводит роли и их права на уже существующей базе в соответствие с .env и grants.sql:
-- меняет пароли ролей (init-скрипты исполняются только на пустом томе) и пересобирает
-- права. Безопасно запускать повторно.
--
--   docker compose exec -T postgres psql -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
--       -v ON_ERROR_STOP=1 -f /docker-entrypoint-initdb.d/roles/sync.sql
-- =============================================================

\i /docker-entrypoint-initdb.d/roles/create_roles.sql
\i /docker-entrypoint-initdb.d/roles/grants.sql
