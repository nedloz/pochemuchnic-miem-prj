-- =============================================================
-- 010_user_avatar.sql
-- Аватар пользователя: в auth.user_profiles колонки avatar_key (ключ объекта в MinIO, бакет
-- avatars) и avatar_url (путь API для <img src>). Сама картинка лежит в MinIO; бакет создаёт
-- minio-init, права auth-svc на него задаёт infra/mtls/minio.conf.
--
-- init.sql делает то же самое на пустом volume; этот файл — для уже поднятых баз.
-- Повторный запуск безопасен (IF NOT EXISTS).
--
--   psql "$POSTGRES_ADMIN_URL" -f 010_user_avatar.sql
-- =============================================================

\set ON_ERROR_STOP on

SET ROLE app_owner;

ALTER TABLE auth.user_profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE auth.user_profiles ADD COLUMN IF NOT EXISTS avatar_key TEXT;

RESET ROLE;
