-- =============================================================
-- 011_notebook_pipeline.sql
-- Перенос ноутбучного RAG-конвейера в сервисы: модель эмбеддингов multilingual-e5-base (768 вместо 1024),
-- быстрые ответы (library.quick_answers, library.quick_answer_variants) и ссылки (library.links).
--
-- Векторы разной модели несравнимы, поэтому library.chunk_embeddings очищается, колонка
-- переводится на VECTOR(768), а проиндексированные документы возвращаются в pending: ingest-worker
-- пересчитает их новой моделью (триггер documents_ingest_notify разбудит воркера).
-- graph.entities.name_embedding остаётся VECTOR(1024) и не затрагивается.
--
-- Применять вместе с EMBEDDING_DIM=768 и EMBEDDER_MODEL_NAME=intfloat/multilingual-e5-base в .env.
-- init.sql делает то же самое на пустом volume (\set embedding_dim 768); этот файл — для поднятых баз.
-- Повторный запуск безопасен: пересоздание вектора выполняется только пока колонка не 768,
-- иначе уже пересчитанные эмбеддинги были бы стёрты.
--
--   psql "$POSTGRES_ADMIN_URL" -f 011_notebook_pipeline.sql
-- =============================================================

\set ON_ERROR_STOP on

SET ROLE app_owner;

DO $$
BEGIN
    IF core.vector_column_dimension('library.chunk_embeddings', 'embedding') IS DISTINCT FROM 768 THEN
        -- Старые векторы не приводятся к новой размерности, их можно только пересчитать.
        DELETE FROM library.chunk_embeddings;
        DROP INDEX IF EXISTS library.idx_chunks_embedding_hnsw;
        DROP INDEX IF EXISTS library.idx_chunks_embedding_ivfflat;
        ALTER TABLE library.chunk_embeddings ALTER COLUMN embedding TYPE VECTOR(768);

        -- Тот же выбор индекса, что в init.sql (IVFFlat на пустой таблице не строим).
        IF EXISTS (SELECT 1 FROM pg_am WHERE amname = 'hnsw') THEN
            CREATE INDEX idx_chunks_embedding_hnsw
                ON library.chunk_embeddings USING hnsw (embedding vector_cosine_ops);
        END IF;

        -- Триггер documents_ingest_reset (006) обнуляет ingest_attempts при indexed → pending;
        -- явное присваивание нужно для failed и на случай отсутствия триггера.
        UPDATE library.documents
        SET ingest_status = 'pending',
            ingest_attempts = 0,
            ingest_next_attempt_at = NULL,
            ingest_error = NULL
        WHERE ingest_status = 'indexed';
    END IF;
END $$;

-- Быстрые ответы: готовый ответ на частый вопрос, минуя RAG. Вариант — формулировка вопроса
-- (основной вопрос и каждый вариант хранятся отдельными строками), по ней идёт векторный поиск.
-- embedding заполняет ingest-worker; пока он NULL, вариант не участвует в поиске.
CREATE TABLE IF NOT EXISTS library.quick_answers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    question TEXT NOT NULL UNIQUE,
    answer TEXT NOT NULL,
    source TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS library.quick_answer_variants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    quick_answer_id UUID NOT NULL REFERENCES library.quick_answers(id) ON DELETE CASCADE,
    text TEXT NOT NULL,
    embedding VECTOR(768),
    embedding_model TEXT,
    UNIQUE(quick_answer_id, text)
);

-- Полезные ссылки (описание → url), подмешиваются в ответ по близости описания к вопросу.
CREATE TABLE IF NOT EXISTS library.links (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    description TEXT NOT NULL,
    url TEXT NOT NULL UNIQUE,
    embedding VECTOR(768),
    embedding_model TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE
);

-- Уведомление воркеру: строка без вектора ждёт эмбеддинга. Канал тот же, что у документов
-- (INGEST_NOTIFY_CHANNEL у ingest-worker); в payload — таблица и id строки.
CREATE OR REPLACE FUNCTION library.embedding_pending_notify()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_notify('ingest_jobs', TG_TABLE_NAME || ':' || NEW.id::text);
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_quick_answer_variants_ingest_notify ON library.quick_answer_variants;
CREATE TRIGGER trg_quick_answer_variants_ingest_notify
    AFTER INSERT OR UPDATE ON library.quick_answer_variants
    FOR EACH ROW WHEN (NEW.embedding IS NULL)
    EXECUTE FUNCTION library.embedding_pending_notify();

DROP TRIGGER IF EXISTS trg_links_ingest_notify ON library.links;
CREATE TRIGGER trg_links_ingest_notify
    AFTER INSERT OR UPDATE ON library.links
    FOR EACH ROW WHEN (NEW.embedding IS NULL)
    EXECUTE FUNCTION library.embedding_pending_notify();

RESET ROLE;
