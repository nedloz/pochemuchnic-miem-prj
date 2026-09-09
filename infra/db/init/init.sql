-- =============================================================
-- 001_init.sql (combined)
-- Runs automatically from /docker-entrypoint-initdb.d/ on FIRST init (empty data volume).
-- =============================================================

\set ON_ERROR_STOP on

-- ============================================================
-- 0) КОНСТАНТЫ (меняешь только здесь)
--    ВАЖНО: значения без кавычек. Пароли без пробелов.
-- ============================================================


\set db_name        app_db

\set admin_user     app_user
\set admin_pass     app_password

\set auth_user      auth_user
\set auth_pass      auth_password

\set library_user   library_user
\set library_pass   library_password

\set chat_user      chat_user
\set chat_pass      chat_password

\set graph_user     graph_user
\set graph_pass     graph_password

-- Сид-администратор. Создаётся при первой инициализации базы, чтобы вход в админ-панель
-- был возможен сразу после `docker compose up`: роль admin ставится только в БД, а до БД
-- добираются через саму панель — без сида это замкнутый круг (см. services/db-svc/README.md).
-- ВАЖНО: пароль ниже — для локальной разработки. Перед выкладкой наружу смените его
-- или удалите этого пользователя.
-- Домен обязан быть @edu.hse.ru: фронтенд проверяет его в isValidEmail() ДО отправки запроса
-- (main/frontend/src/shared/lib/validators.js) и на отказ показывает тот же текст, что и на
-- неверный пароль. С любым другим адресом форма входа молча не отправляет запрос вообще.
-- Служебные TLD (.local, .test, .example, localhost) отпадают и по второй причине: auth-svc
-- валидирует адрес через pydantic EmailStr, который их отвергает.
\set seed_admin_email     admin@edu.hse.ru
\set seed_admin_password  admin

-- Размерность векторов модели эмбеддингов (mxbai-embed-large-v1 → 1024).
-- Должна совпадать с EMBEDDING_DIM в корневом .env: ingest-worker и graph-rag-svc
-- сверяют это значение с фактическим типом колонки при запуске и не стартуют при
-- расхождении. Смена модели эмбеддингов требует пересчёта всех чанков и всего графа.
\set embedding_dim  1024


-- =============================================================
-- FULL SCHEMA INIT (core + auth + chat + library)
-- - Creates required schemas
-- - Loads required extensions (pgcrypto, citext, vector)
-- - Uses gen_random_uuid() (no uuid-ossp dependency)
-- - pgvector tables/indexes ENABLED (IVFFlat, since HNSW may be unavailable)
-- =============================================================

-- -------------------------
-- Extensions
-- -------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;    -- CITEXT type
CREATE EXTENSION IF NOT EXISTS vector;    -- pgvector

-- -------------------------
-- Schemas
-- -------------------------
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS chat;
CREATE SCHEMA IF NOT EXISTS library;
CREATE SCHEMA IF NOT EXISTS graph;

-- =============================================================
-- CORE
-- =============================================================

CREATE TABLE IF NOT EXISTS core.universities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    short_name TEXT,
    timezone TEXT,
    website_url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT universities_name_unique UNIQUE (name),
    CONSTRAINT universities_short_name_unique UNIQUE (short_name)
);

CREATE TABLE IF NOT EXISTS core.campuses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    university_id UUID NOT NULL REFERENCES core.universities(id) ON DELETE CASCADE,
    city TEXT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_campuses_university_id
    ON core.campuses(university_id);

CREATE TABLE IF NOT EXISTS core.faculties (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    university_id UUID NOT NULL REFERENCES core.universities(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    short_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT faculties_university_id_name_key UNIQUE (university_id, name)
);

CREATE INDEX IF NOT EXISTS idx_faculties_university_id
    ON core.faculties(university_id);

CREATE TABLE IF NOT EXISTS core.buildings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campus_id UUID NOT NULL REFERENCES core.campuses(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    address TEXT,
    map_url TEXT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()

);

CREATE INDEX IF NOT EXISTS idx_buildings_campus_id
    ON core.buildings(campus_id);

CREATE TABLE IF NOT EXISTS core.programs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    faculty_id UUID NOT NULL REFERENCES core.faculties(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    short_name TEXT,
    code TEXT,
    degree_level TEXT,
    study_form TEXT,
    language TEXT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT programs_faculty_id_name_key UNIQUE (faculty_id, name)
);

CREATE INDEX IF NOT EXISTS idx_programs_faculty_id
    ON core.programs(faculty_id);

-- =============================================================
-- AUTH
-- =============================================================

CREATE TABLE IF NOT EXISTS auth.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email CITEXT NOT NULL,
    password_hash TEXT NOT NULL,
    is_email_verified BOOLEAN NOT NULL DEFAULT false,
    role TEXT NOT NULL DEFAULT 'student' CHECK (role IN ('student','curator','admin')),
    is_active BOOLEAN NOT NULL DEFAULT true,
    last_login_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT users_email_key UNIQUE (email)
);

CREATE INDEX IF NOT EXISTS idx_users_role
    ON auth.users(role);

CREATE INDEX IF NOT EXISTS idx_users_is_active
    ON auth.users(is_active);

CREATE TABLE IF NOT EXISTS auth.user_profiles (
    user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    first_name TEXT,
    last_name TEXT,
    telegram_username TEXT,

    university_id UUID REFERENCES core.universities(id) ON DELETE SET NULL,
    campus_id UUID REFERENCES core.campuses(id) ON DELETE SET NULL,
    faculty_id UUID REFERENCES core.faculties(id) ON DELETE SET NULL,
    program_id UUID REFERENCES core.programs(id) ON DELETE SET NULL,

    year INT CHECK (year IS NULL OR (year >= 1 AND year <= 6)),
    group_name TEXT,
    preferences_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_profiles_university
    ON auth.user_profiles(university_id);

CREATE INDEX IF NOT EXISTS idx_profiles_campus
    ON auth.user_profiles(campus_id);

CREATE INDEX IF NOT EXISTS idx_profiles_faculty
    ON auth.user_profiles(faculty_id);

CREATE INDEX IF NOT EXISTS idx_profiles_program
    ON auth.user_profiles(program_id);

CREATE TABLE IF NOT EXISTS auth.refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL,
    revoked_at TIMESTAMPTZ,
    replaced_by_token_id UUID REFERENCES auth.refresh_tokens(id) ON DELETE SET NULL,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT refresh_tokens_token_hash_key UNIQUE (token_hash)
);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user
    ON auth.refresh_tokens(user_id);

CREATE INDEX IF NOT EXISTS idx_refresh_tokens_revoked_at
    ON auth.refresh_tokens(revoked_at);

CREATE TABLE IF NOT EXISTS auth.email_verifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    email CITEXT NOT NULL,
    token_hash TEXT NOT NULL,
    used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT email_verifications_token_hash_key UNIQUE (token_hash)
);

CREATE INDEX IF NOT EXISTS idx_email_verifications_user
    ON auth.email_verifications(user_id);

CREATE INDEX IF NOT EXISTS idx_email_verifications_used_at
    ON auth.email_verifications(used_at);

CREATE TABLE IF NOT EXISTS auth.password_resets (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL,
    used_at TIMESTAMPTZ,
    requested_ip INET,
    requested_user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT password_resets_token_hash_key UNIQUE (token_hash)
);

CREATE INDEX IF NOT EXISTS idx_password_resets_user
    ON auth.password_resets(user_id);

CREATE INDEX IF NOT EXISTS idx_password_resets_used_at
    ON auth.password_resets(used_at);

-- =============================================================
-- CHAT
-- =============================================================

CREATE TABLE IF NOT EXISTS chat.chat_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    last_message_at TIMESTAMPTZ,
    last_message_id UUID,
    is_archived BOOLEAN NOT NULL DEFAULT false,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_chat_sessions_user_id
    ON chat.chat_sessions(user_id);

CREATE INDEX IF NOT EXISTS idx_chat_sessions_last_message_at
    ON chat.chat_sessions(last_message_at);

CREATE TABLE IF NOT EXISTS chat.chat_messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id UUID NOT NULL REFERENCES chat.chat_sessions(id) ON DELETE CASCADE,
    user_id UUID REFERENCES auth.users(id),
    role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
    content TEXT NOT NULL,
    reply_to_message_id UUID REFERENCES chat.chat_messages(id) ON DELETE SET NULL,
    latency_ms INT CHECK (latency_ms IS NULL OR latency_ms >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_chat_messages_session_created_at
    ON chat.chat_messages(session_id, created_at);

CREATE INDEX IF NOT EXISTS idx_chat_messages_user_id
    ON chat.chat_messages(user_id);

CREATE INDEX IF NOT EXISTS idx_chat_messages_reply_to
    ON chat.chat_messages(reply_to_message_id);

CREATE TABLE IF NOT EXISTS chat.feedback (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID NOT NULL REFERENCES chat.chat_messages(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES auth.users(id),
    helpful INT NOT NULL CHECK (helpful >= 1 AND helpful <= 5),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE(message_id, user_id)
);

CREATE INDEX IF NOT EXISTS idx_feedback_message_id
    ON chat.feedback(message_id);

CREATE INDEX IF NOT EXISTS idx_feedback_user_id
    ON chat.feedback(user_id);

CREATE TABLE IF NOT EXISTS chat.rag_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID NOT NULL REFERENCES chat.chat_messages(id) ON DELETE CASCADE,
    query_text TEXT NOT NULL,
    query_embedding_model TEXT,
    filters_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    retrieved_chunk_ids UUID[] NOT NULL DEFAULT ARRAY[]::uuid[],
    retrieved_doc_ids UUID[] NOT NULL DEFAULT ARRAY[]::uuid[],
    scores_json JSONB NOT NULL DEFAULT '[]'::jsonb,
    retrieval_ms INT CHECK (retrieval_ms IS NULL OR retrieval_ms >= 0),
    prompt_tokens INT CHECK (prompt_tokens IS NULL OR prompt_tokens >= 0),
    completion_tokens INT CHECK (completion_tokens IS NULL OR completion_tokens >= 0),
    total_tokens INT CHECK (total_tokens IS NULL OR total_tokens >= 0),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_rag_runs_message_id
    ON chat.rag_runs(message_id);

CREATE INDEX IF NOT EXISTS idx_rag_runs_created_at
    ON chat.rag_runs(created_at);

-- =============================================================
-- LIBRARY (RAG knowledge base)
-- =============================================================

CREATE TABLE IF NOT EXISTS library.topics (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    parent_id UUID REFERENCES library.topics(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    slug TEXT NOT NULL UNIQUE,
    description TEXT,
    order_index INT NOT NULL DEFAULT 0,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_topics_parent_id
    ON library.topics(parent_id);

CREATE TABLE IF NOT EXISTS library.documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    topic_id UUID REFERENCES library.topics(id) ON DELETE SET NULL,
    title TEXT NOT NULL,
    category TEXT NOT NULL,
    source_type TEXT NOT NULL,
    content_type TEXT NOT NULL,
    language TEXT NOT NULL DEFAULT 'ru',
    status TEXT NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','published','archived')),
    priority INT NOT NULL DEFAULT 0,

    origin_url TEXT,
    checksum TEXT,
    scope_json JSONB NOT NULL DEFAULT '{}'::jsonb,

    ingest_status TEXT NOT NULL DEFAULT 'pending',
    indexed_at TIMESTAMPTZ,
    ingest_error TEXT,
    content_version INT NOT NULL DEFAULT 1,

    created_by UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_docs_topic
    ON library.documents(topic_id);

CREATE INDEX IF NOT EXISTS idx_docs_status
    ON library.documents(status);

CREATE INDEX IF NOT EXISTS idx_docs_category
    ON library.documents(category);

CREATE TABLE IF NOT EXISTS library.chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id UUID NOT NULL REFERENCES library.documents(id) ON DELETE CASCADE,
    chunk_index INT NOT NULL,
    section_path TEXT,
    start_offset INT,
    end_offset INT,
    text TEXT NOT NULL,
    token_count INT CHECK (token_count IS NULL OR token_count >= 0),
    metadata_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE(document_id, chunk_index)
);

CREATE INDEX IF NOT EXISTS idx_chunks_document_id
    ON library.chunks(document_id);

-- pgvector: embeddings table (ENABLED)
CREATE TABLE IF NOT EXISTS library.chunk_embeddings (
    chunk_id UUID PRIMARY KEY REFERENCES library.chunks(id) ON DELETE CASCADE,
    embedding VECTOR(:embedding_dim) NOT NULL,
    embedding_model TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Vector index:
-- Prefer HNSW if available (good recall even on small data).
-- If HNSW is not available, skip IVFFlat on empty/small tables to avoid low-recall index warnings.
DO $$
BEGIN
  -- Create vector index in a safe way:
  -- - Prefer HNSW when available (good even with small data).
  -- - Only create IVFFlat after the table has enough rows to avoid low-recall training.
  IF to_regclass('library.chunk_embeddings') IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_am WHERE amname = 'hnsw') THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_chunks_embedding_hnsw ' ||
            'ON library.chunk_embeddings USING hnsw (embedding vector_cosine_ops)';
  ELSE
    IF COALESCE(
         (SELECT reltuples::bigint
          FROM pg_class
          WHERE oid = to_regclass('library.chunk_embeddings')),
         0
       ) >= 10000 THEN
      EXECUTE 'CREATE INDEX IF NOT EXISTS idx_chunks_embedding_ivfflat ' ||
              'ON library.chunk_embeddings USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)';
    END IF;
  END IF;
END $$;
CREATE TABLE IF NOT EXISTS library.document_files (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id UUID NOT NULL REFERENCES library.documents(id) ON DELETE CASCADE,
    storage_backend TEXT NOT NULL DEFAULT 'local',
    bucket TEXT,
    storage_key TEXT,
    storage_path TEXT NOT NULL,
    file_name TEXT,
    mime_type TEXT,
    size_bytes BIGINT CHECK (size_bytes IS NULL OR size_bytes >= 0),
    sha256_hash TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_document_files_document_id
    ON library.document_files(document_id);

CREATE TABLE IF NOT EXISTS library.document_relations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    from_document_id UUID NOT NULL REFERENCES library.documents(id) ON DELETE CASCADE,
    to_document_id UUID NOT NULL REFERENCES library.documents(id) ON DELETE CASCADE,
    relation_type TEXT NOT NULL,
    label TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE(from_document_id, to_document_id, relation_type)
);

CREATE INDEX IF NOT EXISTS idx_doc_relations_from
    ON library.document_relations(from_document_id);

CREATE INDEX IF NOT EXISTS idx_doc_relations_to
    ON library.document_relations(to_document_id);

CREATE TABLE IF NOT EXISTS library.contacts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    role TEXT,
    email TEXT,
    phone TEXT,
    website_url TEXT,
    office_text TEXT,
    building_id UUID REFERENCES core.buildings(id) ON DELETE SET NULL,
    floor TEXT,
    room TEXT,
    hours_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    description TEXT,
    notes TEXT,
    scope_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_contacts_building_id
    ON library.contacts(building_id);

CREATE TABLE IF NOT EXISTS library.places (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    place_type TEXT,
    building_id UUID REFERENCES core.buildings(id) ON DELETE SET NULL,
    address_text TEXT,
    floor TEXT,
    room TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    description TEXT,
    how_to_find TEXT,
    hours_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    contacts_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    map_url TEXT,
    scope_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_places_building_id
    ON library.places(building_id);

CREATE INDEX IF NOT EXISTS idx_places_type
    ON library.places(place_type);

-- =============================================================
-- GRAPH (entity/relation knowledge graph for graph-rag-svc)
-- - Populated offline by graph-rag-svc's graph-builder CLI from library.chunks
-- - Read/queried online by graph-rag-svc's retrieval pipeline
-- =============================================================

CREATE TABLE IF NOT EXISTS graph.extraction_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    run_type TEXT NOT NULL,                  -- 'full_rebuild' | 'incremental' | 'bootstrap_jsonl'
    extraction_model TEXT,
    ontology_version TEXT NOT NULL,
    document_ids UUID[],                     -- NULL = all documents
    status TEXT NOT NULL DEFAULT 'running',  -- 'running' | 'completed' | 'failed'
    stats_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS graph.entities (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type TEXT NOT NULL,             -- fixed ontology: Студент, Преподаватель, Учебный офис, Приказ, ...
    canonical_name TEXT NOT NULL,
    name_embedding VECTOR(:embedding_dim), -- same model/dims as library.chunk_embeddings; NULL until backfilled
    embedding_model TEXT,
    attributes_json JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE(entity_type, canonical_name)
);

CREATE TABLE IF NOT EXISTS graph.entity_aliases (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id UUID NOT NULL REFERENCES graph.entities(id) ON DELETE CASCADE,
    alias TEXT NOT NULL,
    alias_normalized TEXT NOT NULL,        -- lowercased/trimmed, indexed for fast exact lookup
    source TEXT NOT NULL DEFAULT 'extraction',  -- 'extraction' | 'manual' | 'llm_merge'
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE(entity_id, alias_normalized)
);

CREATE INDEX IF NOT EXISTS idx_entity_aliases_normalized
    ON graph.entity_aliases(alias_normalized);

CREATE TABLE IF NOT EXISTS graph.relations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_entity_id UUID NOT NULL REFERENCES graph.entities(id) ON DELETE CASCADE,
    object_entity_id UUID NOT NULL REFERENCES graph.entities(id) ON DELETE CASCADE,
    relation TEXT NOT NULL,                -- infinitive verb, per ontology convention
    confidence REAL,
    extraction_run_id UUID REFERENCES graph.extraction_runs(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE(subject_entity_id, object_entity_id, relation)
);

CREATE INDEX IF NOT EXISTS idx_relations_subject
    ON graph.relations(subject_entity_id);

CREATE INDEX IF NOT EXISTS idx_relations_object
    ON graph.relations(object_entity_id);

CREATE TABLE IF NOT EXISTS graph.entity_source_chunks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_id UUID REFERENCES graph.entities(id) ON DELETE CASCADE,
    relation_id UUID REFERENCES graph.relations(id) ON DELETE CASCADE,
    chunk_id UUID NOT NULL REFERENCES library.chunks(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    CHECK (entity_id IS NOT NULL OR relation_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS idx_entity_source_chunks_chunk
    ON graph.entity_source_chunks(chunk_id);

-- =========================================================
-- Схема rag: нейтральная аналитика ретривала, общая для обоих проектов.
-- У соседнего проекта нет схемы chat, поэтому аналог chat.rag_runs нужен вне её.
-- Пишут оба экземпляра graph-rag-svc; колонка consumer разделяет трафик команд.
-- =========================================================
CREATE SCHEMA IF NOT EXISTS rag;

CREATE TABLE IF NOT EXISTS rag.retrieval_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id TEXT NOT NULL,
    consumer TEXT,
    session_id TEXT,
    user_id TEXT,
    question TEXT NOT NULL,
    route_used TEXT,
    query_embedding_model TEXT,
    retrieved_chunk_ids UUID[],
    retrieved_doc_ids UUID[],
    scores_json JSONB,
    retrieval_ms DOUBLE PRECISION,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    total_tokens INTEGER,
    status TEXT NOT NULL DEFAULT 'completed',
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_retrieval_runs_created_at
    ON rag.retrieval_runs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_retrieval_runs_consumer
    ON rag.retrieval_runs(consumer);

-- Стоп-лист ручного курирования: построение графа идёт через upsert, поэтому просто
-- удалённая сущность была бы заново создана следующей пересборкой. Проверяется в
-- app/graph/resolution.py::resolve_entity.
CREATE TABLE IF NOT EXISTS graph.curation_blocklist (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name_normalized TEXT NOT NULL UNIQUE,
    reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- pgvector index on entity name embeddings (same safe-creation pattern as library.chunk_embeddings)
DO $$
BEGIN
  IF to_regclass('graph.entities') IS NULL THEN
    RETURN;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_am WHERE amname = 'hnsw') THEN
    EXECUTE 'CREATE INDEX IF NOT EXISTS idx_graph_entities_embedding_hnsw ' ||
            'ON graph.entities USING hnsw (name_embedding vector_cosine_ops)';
  ELSE
    IF COALESCE(
         (SELECT reltuples::bigint
          FROM pg_class
          WHERE oid = to_regclass('graph.entities')),
         0
       ) >= 10000 THEN
      EXECUTE 'CREATE INDEX IF NOT EXISTS idx_graph_entities_embedding_ivfflat ' ||
              'ON graph.entities USING ivfflat (name_embedding vector_cosine_ops) WITH (lists = 100)';
    END IF;
  END IF;
END $$;

-- =============================================================
-- Notes for IVFFlat
-- After inserting/updating a lot of rows in library.chunk_embeddings:
--   ANALYZE library.chunk_embeddings;
-- And for better recall (per session):
--   SET ivfflat.probes = 10;  -- tune 1..100
-- =============================================================

-- ============================================================
-- 1.9) СИД: администратор по умолчанию
--    Хеш пароля считается тем же bcrypt, что использует auth-svc (passlib/bcrypt
--    читает формат $2a$, который выдаёт pgcrypto), поэтому обычный логин через
--    POST /auth/login с этим паролем работает без дополнительных шагов.
--    Профиль создаётся сразу: GET /users/me отвечает 404, если строки профиля нет,
--    а фронтенд без него не покажет кнопку входа в админку.
-- ============================================================

INSERT INTO auth.users (email, password_hash, role, is_email_verified, is_active)
VALUES (
    :'seed_admin_email',
    crypt(:'seed_admin_password', gen_salt('bf', 12)),
    'admin',
    true,
    true
)
ON CONFLICT (email) DO NOTHING;

INSERT INTO auth.user_profiles (user_id, first_name, last_name)
SELECT id, 'Admin', 'Pochemuchnik'
FROM auth.users
WHERE email = :'seed_admin_email'
ON CONFLICT (user_id) DO NOTHING;

-- ============================================================
-- 2) РОЛИ + ПРАВА (после создания схем/таблиц)
-- ============================================================

-- 2.1) Роли (CREATE ROLE IF NOT EXISTS) через psql \gexec
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'admin_user', :'admin_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'admin_user')
\gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'auth_user', :'auth_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'auth_user')
\gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'library_user', :'library_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'library_user')
\gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'chat_user', :'chat_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'chat_user')
\gexec

SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'graph_user', :'graph_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'graph_user')
\gexec

-- 2.2) Запретить PUBLIC лишнее на БД
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db_name')
\gexec


SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db_name')
\gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'auth_user')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'library_user')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'chat_user')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'graph_user')
\gexec
-- (опционально) админу:
SELECT format('GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I', :'db_name', :'admin_user')
\gexec

-- 2.4) Доступ к схемам
SELECT format('GRANT USAGE ON SCHEMA core, auth, library, chat, graph TO %I', :'admin_user')
\gexec

SELECT format('GRANT USAGE ON SCHEMA core TO %I, %I, %I, %I', :'auth_user', :'library_user', :'chat_user', :'graph_user')
\gexec

SELECT format('GRANT USAGE ON SCHEMA auth TO %I', :'auth_user')
\gexec
SELECT format('GRANT USAGE ON SCHEMA library TO %I', :'library_user')
\gexec
SELECT format('GRANT USAGE ON SCHEMA chat TO %I', :'chat_user')
\gexec
SELECT format('GRANT USAGE ON SCHEMA graph TO %I', :'graph_user')
\gexec
SELECT format('GRANT USAGE ON SCHEMA rag TO %I', :'graph_user')
\gexec
-- graph-rag-svc reads chunks/documents from library (read-only), never writes there
SELECT format('GRANT USAGE ON SCHEMA library TO %I', :'graph_user')
\gexec

-- 2.5) Права на существующие таблицы/последовательности
SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core, auth, library, chat, graph TO %I', :'admin_user')
\gexec
SELECT format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA core, auth, library, chat, graph TO %I', :'admin_user')
\gexec

SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA core TO %I, %I, %I, %I', :'auth_user', :'library_user', :'chat_user', :'graph_user')
\gexec
SELECT format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA core TO %I, %I, %I, %I', :'auth_user', :'library_user', :'chat_user', :'graph_user')
\gexec

-- graph-rag-svc: read-only on library (chunks/documents), full CRUD on its own `graph` schema
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA library TO %I', :'graph_user')
\gexec
SELECT format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA library TO %I', :'graph_user')
\gexec
SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA graph TO %I', :'graph_user')
\gexec
SELECT format('GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA rag TO %I', :'graph_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA rag GRANT SELECT, INSERT ON TABLES TO %I', :'graph_user')
\gexec
SELECT format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA graph TO %I', :'graph_user')
\gexec

SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA auth TO %I', :'auth_user')
\gexec
SELECT format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA auth TO %I', :'auth_user')
\gexec

SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA library TO %I', :'library_user')
\gexec
SELECT format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA library TO %I', :'library_user')
\gexec

SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA chat TO %I', :'chat_user')
\gexec
SELECT format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA chat TO %I', :'chat_user')
\gexec

-- 2.6) Default privileges (для будущих объектов владельца, который создаёт таблицы)
-- ADMIN: полный доступ на будущее
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA core GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', :'admin_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA core GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', :'admin_user')
\gexec

SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', :'admin_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', :'admin_user')
\gexec

SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA library GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', :'admin_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA library GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', :'admin_user')
\gexec

SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA chat GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', :'admin_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA chat GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', :'admin_user')
\gexec

SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA graph GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', :'admin_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA graph GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', :'admin_user')
\gexec

-- core: чтение на будущее всем сервисам
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA core GRANT SELECT ON TABLES TO %I, %I, %I, %I', :'auth_user', :'library_user', :'chat_user', :'graph_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA core GRANT USAGE, SELECT ON SEQUENCES TO %I, %I, %I, %I', :'auth_user', :'library_user', :'chat_user', :'graph_user')
\gexec

-- library: чтение на будущее graph-rag-svc (read-only)
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA library GRANT SELECT ON TABLES TO %I', :'graph_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA library GRANT USAGE, SELECT ON SEQUENCES TO %I', :'graph_user')
\gexec

-- приватные схемы: полные права своему сервису на будущее
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', :'auth_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA auth GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', :'auth_user')
\gexec

SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA library GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', :'library_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA library GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', :'library_user')
\gexec

SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA chat GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', :'chat_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA chat GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', :'chat_user')
\gexec

SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA graph GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', :'graph_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA graph GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', :'graph_user')
\gexec

-- 2.7) search_path
SELECT format('ALTER ROLE %I SET search_path = core, auth, library, chat, graph, public', :'admin_user')
\gexec

SELECT format('ALTER ROLE %I SET search_path = auth, core, public', :'auth_user')
\gexec
SELECT format('ALTER ROLE %I SET search_path = library, core, public', :'library_user')
\gexec
SELECT format('ALTER ROLE %I SET search_path = chat, core, public', :'chat_user')
\gexec
SELECT format('ALTER ROLE %I SET search_path = graph, library, core, public', :'graph_user')
\gexec
-- 2.3) Закрываем схемы для PUBLIC
REVOKE ALL ON SCHEMA core FROM PUBLIC;
REVOKE ALL ON SCHEMA auth FROM PUBLIC;
REVOKE ALL ON SCHEMA library FROM PUBLIC;
REVOKE ALL ON SCHEMA chat FROM PUBLIC;
REVOKE ALL ON SCHEMA graph FROM PUBLIC;
