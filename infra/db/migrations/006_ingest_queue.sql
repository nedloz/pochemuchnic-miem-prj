-- =============================================================
-- 006_ingest_queue.sql
-- Очередь индексации для ingest-worker: повторы с отложенным временем, возврат брошенных
-- документов и уведомление воркера через LISTEN/NOTIFY вместо опроса раз в 5 секунд.
-- Подробности — services/ingest-worker/README.md, раздел «Очередь и повторы».
--
-- init.sql делает то же самое на пустом volume; этот файл — для уже поднятых баз.
-- Повторный запуск безопасен (IF NOT EXISTS / CREATE OR REPLACE / DROP TRIGGER IF EXISTS).
-- Применять ДО запуска новой версии ingest-worker: без этих колонок он не сможет выбрать задачу.
--
--   psql "$POSTGRES_ADMIN_URL" -f 006_ingest_queue.sql
-- =============================================================

\set ON_ERROR_STOP on

ALTER TABLE library.documents
    ADD COLUMN IF NOT EXISTS ingest_attempts INT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS ingest_next_attempt_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS ingest_started_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_docs_ingest_queue
    ON library.documents(ingest_next_attempt_at)
    WHERE ingest_status IN ('pending', 'processing');

-- Документ, который вручную или новой версией вернули из indexed/failed в pending, получает
-- полный запас попыток. Отложенный повтор самого воркера идёт из processing — его не трогаем.
CREATE OR REPLACE FUNCTION library.documents_ingest_reset()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.ingest_status = 'pending' AND OLD.ingest_status IN ('indexed', 'failed') THEN
        NEW.ingest_attempts := 0;
        NEW.ingest_next_attempt_at := NULL;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_documents_ingest_reset ON library.documents;
CREATE TRIGGER trg_documents_ingest_reset
    BEFORE UPDATE OF ingest_status ON library.documents
    FOR EACH ROW EXECUTE FUNCTION library.documents_ingest_reset();

-- Уведомление воркеру о новой задаче. Шлёт сама БД, поэтому сервисы, создающие документы
-- (library-svc, db-svc, crawler-svc), об очереди не знают и не менялись. NOTIFY доставляется
-- при COMMIT, так что воркер не увидит незакоммиченную строку. Имя канала должно совпадать
-- с INGEST_NOTIFY_CHANNEL у ingest-worker.
CREATE OR REPLACE FUNCTION library.documents_ingest_notify()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.ingest_status = 'pending' THEN
        PERFORM pg_notify('ingest_jobs', NEW.id::text);
    END IF;
    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_documents_ingest_notify ON library.documents;
CREATE TRIGGER trg_documents_ingest_notify
    AFTER INSERT OR UPDATE OF ingest_status ON library.documents
    FOR EACH ROW EXECUTE FUNCTION library.documents_ingest_notify();

