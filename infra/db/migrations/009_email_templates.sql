-- =============================================================
-- 009_email_templates.sql
-- Тексты писем в БД: core.email_templates. Редактируются в админке (db-svc, вкладка «Письма»,
-- core_rw), читаются auth-svc при отправке (core_ro). Права выдаются default privileges
-- владельца схемы, отдельный GRANT не нужен.
--
-- init.sql делает то же самое на пустом volume; этот файл — для уже поднятых баз.
-- Повторный запуск безопасен (IF NOT EXISTS / ON CONFLICT DO NOTHING).
--
--   psql "$POSTGRES_ADMIN_URL" -f 009_email_templates.sql
-- =============================================================

\set ON_ERROR_STOP on

SET ROLE app_owner;

CREATE TABLE IF NOT EXISTS core.email_templates (
    event_type TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    subject_template TEXT NOT NULL,
    body_html TEXT NOT NULL,
    placeholders JSONB NOT NULL DEFAULT '{}'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO core.email_templates (event_type, title, subject_template, body_html, placeholders)
VALUES
    (
        'email_verification',
        'Подтверждение электронной почты',
        'Подтверждение электронной почты',
        '<h2>Подтверждение электронной почты</h2><p>Для подтверждения адреса электронной почты нажмите на кнопку ниже.</p><p><a href="{verification_url}" style="display:inline-block;padding:12px 20px;background:#2563eb;color:#ffffff;text-decoration:none;border-radius:6px;">Подтвердить почту</a></p><p>Если вы не регистрировались в системе, просто проигнорируйте это письмо.</p>',
        '{"verification_url": "Ссылка для подтверждения почты. Действует ограниченное время"}'
    ),
    (
        'password_reset',
        'Сброс пароля',
        'Сброс пароля',
        '<h2>Сброс пароля</h2><p>Для создания нового пароля нажмите на кнопку ниже.</p><p><a href="{reset_url}" style="display:inline-block;padding:12px 20px;background:#2563eb;color:#ffffff;text-decoration:none;border-radius:6px;">Сбросить пароль</a></p><p>Если вы не запрашивали сброс пароля, просто проигнорируйте это письмо.</p>',
        '{"reset_url": "Ссылка для установки нового пароля. Действует ограниченное время"}'
    )
ON CONFLICT (event_type) DO NOTHING;

RESET ROLE;
