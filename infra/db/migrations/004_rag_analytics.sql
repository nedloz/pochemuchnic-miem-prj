-- =============================================================
-- 004_rag_analytics.sql
-- Схема `rag` — нейтральная аналитика ретривала, общая для обоих проектов.
--
-- Зачем отдельная схема, а не chat.rag_runs: у соседнего проекта (Telegram-бот) нет
-- chat-svc и схемы `chat` вообще, а аналитика нужна обоим. Писать в `graph` тоже нельзя —
-- это схема графа, у неё своя модель владения. Поэтому нейтральное место, куда пишут
-- оба экземпляра graph-rag-svc; колонка `consumer` разделяет трафик команд.
--
-- chat.rag_runs при этом сохраняется: там есть связь с chat.messages.message_id, которой
-- у бота нет. Дублирование осознанное (README graph-rag-svc, §12.3).
--
--   psql "$POSTGRES_ADMIN_URL" -v graph_user=graph_user -f 004_rag_analytics.sql
-- =============================================================

\set ON_ERROR_STOP on

\if :{?graph_user}
\else
  \set graph_user graph_user
\endif

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS rag;

CREATE TABLE IF NOT EXISTS rag.retrieval_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id TEXT NOT NULL,
    consumer TEXT,                     -- X-Service-Name вызывающего: чей это трафик
    session_id TEXT,
    user_id TEXT,
    question TEXT NOT NULL,
    route_used TEXT,                   -- graph | vector | graph->vector
    query_embedding_model TEXT,
    retrieved_chunk_ids UUID[],
    retrieved_doc_ids UUID[],
    scores_json JSONB,
    retrieval_ms DOUBLE PRECISION,
    prompt_tokens INTEGER,
    completion_tokens INTEGER,
    total_tokens INTEGER,
    status TEXT NOT NULL DEFAULT 'completed',   -- completed | error
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_retrieval_runs_created_at
    ON rag.retrieval_runs(created_at DESC);
CREATE INDEX IF NOT EXISTS idx_retrieval_runs_consumer
    ON rag.retrieval_runs(consumer);

SELECT format('GRANT USAGE ON SCHEMA rag TO %I', :'graph_user')
\gexec
SELECT format('GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA rag TO %I', :'graph_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA rag GRANT SELECT, INSERT ON TABLES TO %I', :'graph_user')
\gexec
