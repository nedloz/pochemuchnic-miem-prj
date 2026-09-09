-- =============================================================
-- 002_graph_schema.sql
-- Standalone, idempotent migration for the `graph` schema used by graph-rag-svc.
--
-- Unlike init/init.sql, this file is NOT run automatically by Postgres
-- (docker-entrypoint-initdb.d only runs on a fresh/empty data volume).
-- Apply it by hand against an already-initialized dev/staging database:
--
--   psql "$POSTGRES_ADMIN_URL" -v graph_user=graph_user -v graph_pass=graph_password -f 002_graph_schema.sql
--
-- Safe to re-run: every statement uses IF NOT EXISTS / ON CONFLICT-safe DDL.
-- Keep this file's schema/table/role definitions in sync with init/init.sql —
-- init.sql is the source of truth for fresh installs, this file is the
-- catch-up path for existing databases.
-- =============================================================

\set ON_ERROR_STOP on

\if :{?graph_user}
\else
  \set graph_user graph_user
\endif
\if :{?graph_pass}
\else
  \set graph_pass graph_password
\endif
\if :{?db_name}
\else
  \set db_name app_db
\endif
-- Должна совпадать с EMBEDDING_DIM в корневом .env и с library.chunk_embeddings.embedding.
\if :{?embedding_dim}
\else
  \set embedding_dim 1024
\endif

CREATE EXTENSION IF NOT EXISTS pgcrypto;  -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS vector;    -- pgvector

CREATE SCHEMA IF NOT EXISTS graph;

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
    entity_type TEXT NOT NULL,
    canonical_name TEXT NOT NULL,
    name_embedding VECTOR(:embedding_dim),
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
    alias_normalized TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT 'extraction',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),

    UNIQUE(entity_id, alias_normalized)
);

CREATE INDEX IF NOT EXISTS idx_entity_aliases_normalized
    ON graph.entity_aliases(alias_normalized);

CREATE TABLE IF NOT EXISTS graph.relations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subject_entity_id UUID NOT NULL REFERENCES graph.entities(id) ON DELETE CASCADE,
    object_entity_id UUID NOT NULL REFERENCES graph.entities(id) ON DELETE CASCADE,
    relation TEXT NOT NULL,
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

-- -------------------------
-- Role + grants
-- -------------------------
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'graph_user', :'graph_pass')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'graph_user')
\gexec

SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'db_name', :'graph_user')
\gexec

SELECT format('GRANT USAGE ON SCHEMA core TO %I', :'graph_user')
\gexec
SELECT format('GRANT USAGE ON SCHEMA library TO %I', :'graph_user')
\gexec
SELECT format('GRANT USAGE ON SCHEMA graph TO %I', :'graph_user')
\gexec

SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA core TO %I', :'graph_user')
\gexec
SELECT format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA core TO %I', :'graph_user')
\gexec

SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA library TO %I', :'graph_user')
\gexec
SELECT format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA library TO %I', :'graph_user')
\gexec

SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA graph TO %I', :'graph_user')
\gexec
SELECT format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA graph TO %I', :'graph_user')
\gexec

SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA graph GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %I', :'graph_user')
\gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA graph GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I', :'graph_user')
\gexec

SELECT format('ALTER ROLE %I SET search_path = graph, library, core, public', :'graph_user')
\gexec

REVOKE ALL ON SCHEMA graph FROM PUBLIC;
