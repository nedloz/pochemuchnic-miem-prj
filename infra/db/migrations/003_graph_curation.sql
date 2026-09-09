-- =============================================================
-- 003_graph_curation.sql
-- Стоп-лист сущностей для ручного курирования графа.
--
-- Зачем: построение графа идёт через upsert по естественным ключам, поэтому просто
-- удалённая руками сущность будет заново создана следующей же пересборкой. Стоп-лист
-- проверяется в app/graph/resolution.py::resolve_entity и делает удаление устойчивым.
--
-- Применение к уже проинициализированной БД:
--   psql "$POSTGRES_ADMIN_URL" -v graph_user=graph_user -f 003_graph_curation.sql
-- =============================================================

\set ON_ERROR_STOP on

\if :{?graph_user}
\else
  \set graph_user graph_user
\endif

CREATE TABLE IF NOT EXISTS graph.curation_blocklist (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name_normalized TEXT NOT NULL UNIQUE,
    reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE ON graph.curation_blocklist TO %I', :'graph_user')
\gexec
