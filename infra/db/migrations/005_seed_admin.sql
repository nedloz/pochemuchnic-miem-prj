-- =============================================================
-- 005_seed_admin.sql
-- Администратор по умолчанию для уже проинициализированных баз.
--
-- init.sql выполняется только на пустом volume, поэтому у команды, которая подняла
-- стек раньше, сид-администратора нет. Этот файл делает ровно то же, что блок 1.9
-- в init.sql, и повторный запуск ничего не ломает (ON CONFLICT DO NOTHING).
--
--   psql "$POSTGRES_ADMIN_URL" -f 005_seed_admin.sql
--   psql "$POSTGRES_ADMIN_URL" -v seed_admin_password=<свой пароль> -f 005_seed_admin.sql
--
-- ВАЖНО: пароль по умолчанию рассчитан на локальную разработку. Для стенда, доступного
-- снаружи, передайте свой через -v или смените пароль сразу после применения.
-- =============================================================

\set ON_ERROR_STOP on

\if :{?seed_admin_email}
\else
  \set seed_admin_email admin@edu.hse.ru
\endif

\if :{?seed_admin_password}
\else
  \set seed_admin_password admin
\endif

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Хеш считается тем же bcrypt, что проверяет auth-svc: pgcrypto выдаёт формат $2a$,
-- который python-библиотека bcrypt принимает наравне с собственным $2b$.
INSERT INTO auth.users (email, password_hash, role, is_email_verified, is_active)
VALUES (
    :'seed_admin_email',
    crypt(:'seed_admin_password', gen_salt('bf', 12)),
    'admin',
    true,
    true
)
ON CONFLICT (email) DO NOTHING;

-- Если пользователь с таким адресом уже был (например, регистрировался обычным путём),
-- повышаем его до admin, но пароль не трогаем — иначе миграция молча сбросила бы его.
UPDATE auth.users
SET role = 'admin', updated_at = now()
WHERE email = :'seed_admin_email' AND role <> 'admin';

-- Без строки профиля GET /users/me отвечает 404, и фронтенд не покажет кнопку админки.
INSERT INTO auth.user_profiles (user_id, first_name, last_name)
SELECT id, 'Admin', 'Pochemuchnik'
FROM auth.users
WHERE email = :'seed_admin_email'
ON CONFLICT (user_id) DO NOTHING;

SELECT email, role, is_email_verified, is_active
FROM auth.users
WHERE email = :'seed_admin_email';
