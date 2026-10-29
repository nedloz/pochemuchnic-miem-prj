-- =============================================================
-- 013_planner_grades.sql
-- Календарь (library.planner_*) и калькулятор оценок (library.grade_*) для library-svc.
-- Описание полей и API: «Календарь и калькулятор: хранение» (IVHR-98), роуты календаря — IVHR-64.
-- Таблица шаблонов предметов grade_subject_templates остаётся пустой: её наполнит парсер ПУД.
--
-- Права library_user на новые таблицы выдаёт roles/grants.sql, поэтому файл в конце
-- перезапускает его (как 012). init.sql делает то же самое на пустом volume; этот файл — для
-- уже поднятых баз. Повторный запуск безопасен (IF NOT EXISTS).
--
--   docker compose exec -T postgres psql -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" \
--       -v ON_ERROR_STOP=1 < infra/db/migrations/013_planner_grades.sql
-- =============================================================

\set ON_ERROR_STOP on

SET ROLE app_owner;

-- Теги пользователя. Название уникально у пользователя без учёта регистра.
CREATE TABLE IF NOT EXISTS library.planner_tags (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    name        TEXT NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 30),
    color       TEXT NOT NULL CHECK (color ~ '^#[0-9A-Fa-f]{6}$'),
    position    INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS planner_tags_user_name
    ON library.planner_tags (user_id, lower(name));

-- Записи. Даты без времени и часового пояса: запись «на 4 ноября» не должна уезжать на 3-е.
CREATE TABLE IF NOT EXISTS library.planner_notes (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    title       TEXT NOT NULL CHECK (char_length(btrim(title)) BETWEEN 1 AND 80),
    start_date  DATE NOT NULL,
    end_date    DATE NOT NULL,
    description TEXT NOT NULL DEFAULT '' CHECK (char_length(description) <= 500),
    color       TEXT NULL CHECK (color IS NULL OR color ~ '^#[0-9A-Fa-f]{6}$'),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (end_date >= start_date)
);
CREATE INDEX IF NOT EXISTS planner_notes_user_period
    ON library.planner_notes (user_id, start_date, end_date);

-- Теги записи по порядку: position 0 — главный тег, его цвет у записи.
-- Принадлежность тега и записи одному пользователю проверяет приложение.
CREATE TABLE IF NOT EXISTS library.planner_note_tags (
    note_id   UUID NOT NULL REFERENCES library.planner_notes(id) ON DELETE CASCADE,
    tag_id    UUID NOT NULL REFERENCES library.planner_tags(id) ON DELETE CASCADE,
    position  SMALLINT NOT NULL,
    PRIMARY KEY (note_id, tag_id),
    UNIQUE (note_id, position)
);

-- Шаблоны предметов из ПУД (наполняет парсер, правка через админку). Пока пустая.
CREATE TABLE IF NOT EXISTS library.grade_subject_templates (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subject        TEXT NOT NULL,
    course         SMALLINT NOT NULL CHECK (course BETWEEN 1 AND 6),
    program_id     UUID NULL REFERENCES core.programs(id),
    academic_year  TEXT NOT NULL CHECK (academic_year ~ '^\d{4}/\d{4}$'),
    source_url     TEXT NULL,
    rounding       TEXT NOT NULL DEFAULT 'half_up' CHECK (rounding IN ('half_up', 'floor')),
    components     JSONB NOT NULL,
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS grade_subject_templates_unique
    ON library.grade_subject_templates
    (subject, course, coalesce(program_id, '00000000-0000-0000-0000-000000000000'), academic_year);

-- Свои шаблоны пользователя.
CREATE TABLE IF NOT EXISTS library.grade_user_templates (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    name        TEXT NOT NULL CHECK (char_length(btrim(name)) BETWEEN 1 AND 60),
    components  JSONB NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS grade_user_templates_name
    ON library.grade_user_templates (user_id, lower(name));

-- Введённые оценки: строка на пользователя и шаблон (шаблон предмета или свой, поэтому без FK).
-- scores: { "activity": 8, "labs": [9, 7.5, null], "exam": null }
CREATE TABLE IF NOT EXISTS library.grade_user_scores (
    user_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    template_id  UUID NOT NULL,
    scores       JSONB NOT NULL DEFAULT '{}',
    target       SMALLINT NULL CHECK (target BETWEEN 1 AND 10),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, template_id)
);

RESET ROLE;

\i /docker-entrypoint-initdb.d/roles/grants.sql
