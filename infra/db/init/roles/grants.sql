-- =============================================================
-- roles/grants.sql
-- Единственное место, где описаны права ролей. Идемпотентен и каждый раз сначала снимает
-- все права у ролей сервисов и групп в управляемых схемах, а затем выдаёт их заново: так
-- права не накапливаются, а старые широкие (прежнее «полный CRUD на свою схему всем»)
-- исчезают при повторном запуске. Запускать от суперпользователя контейнера, когда таблицы
-- уже созданы: из init.sql — в самом конце, на существующей базе — через migrations/008.
--
-- Принцип: ничего по умолчанию. Каждый сервис получает ровно то, к чему обращается его код.
--   auth-svc     auth.* (чтение/запись), core (чтение)
--   chat-svc     chat.* (чтение/запись), core (чтение)
--   library-svc  каталог: чтение topics, documents, document_files, document_relations;
--                календарь и калькулятор: planner_*, grade_user_* (запись), grade_subject_templates (чтение); core
--   ingest-worker документы: чтение и статусы очереди; чанки и эмбеддинги: запись;
--                быстрые ответы и ссылки: чтение и запись только вектора; core
--   graph-rag-svc graph.* (чтение/запись), library.* (чтение), rag.* (чтение/вставка),
--                core (чтение)
--   db-svc       админка: core и library — запись; graph, chat, rag — чтение (граф правится
--                через graph-rag-svc, а не напрямую); auth — без хешей паролей и токенов
-- =============================================================

\i /docker-entrypoint-initdb.d/roles/vars.sql

-- DO-блок не видит psql-переменных, поэтому имена ролей передаются через настройки сессии.
SELECT set_config('rolesync.auth',    :'auth_user',    false),
       set_config('rolesync.chat',    :'chat_user',    false),
       set_config('rolesync.library', :'library_user', false),
       set_config('rolesync.ingest',  :'ingest_user',  false),
       set_config('rolesync.graph',   :'graph_user',   false),
       set_config('rolesync.dbsvc',   :'dbsvc_user',   false) \gset

DO $sync$
DECLARE
    v_auth    text := current_setting('rolesync.auth');
    v_chat    text := current_setting('rolesync.chat');
    v_library text := current_setting('rolesync.library');
    v_ingest  text := current_setting('rolesync.ingest');
    v_graph   text := current_setting('rolesync.graph');
    v_dbsvc   text := current_setting('rolesync.dbsvc');
    v_owner   constant text := 'app_owner';
    schemas   constant text[] := ARRAY['core', 'auth', 'chat', 'library', 'graph', 'rag'];
    runtime   text[];
    grp       text[] := ARRAY[]::text[];
    s text;
    r text;
    rec record;
    cols text;
BEGIN
    runtime := ARRAY[v_auth, v_chat, v_library, v_ingest, v_graph, v_dbsvc];
    FOREACH s IN ARRAY schemas LOOP
        grp := grp || (s || '_ro') || (s || '_rw');
    END LOOP;

    -- ---------------------------------------------------------------------------
    -- 0. Сброс. Членство в группах, таблицы, последовательности, колонки, схемы и
    --    default privileges (в том числе оставшиеся от прежней схемы, где их выдавал
    --    суперпользователь, создавший объекты).
    -- ---------------------------------------------------------------------------
    FOR rec IN
        SELECT g.rolname AS grp_name, m.rolname AS member_name
        FROM pg_auth_members am
        JOIN pg_roles g ON g.oid = am.roleid
        JOIN pg_roles m ON m.oid = am.member
        WHERE g.rolname = ANY (grp) AND (m.rolname = ANY (runtime) OR m.rolname = ANY (grp))
    LOOP
        EXECUTE format('REVOKE %I FROM %I', rec.grp_name, rec.member_name);
    END LOOP;

    FOREACH s IN ARRAY schemas LOOP
        EXECUTE format('REVOKE ALL ON SCHEMA %I FROM PUBLIC', s);
        FOREACH r IN ARRAY runtime || grp LOOP
            EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM %I', s, r);
            EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM %I', s, r);
            EXECUTE format('REVOKE ALL ON SCHEMA %I FROM %I', s, r);
            EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I REVOKE ALL ON TABLES FROM %I', v_owner, s, r);
            EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I REVOKE ALL ON SEQUENCES FROM %I', v_owner, s, r);
            EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I REVOKE ALL ON TABLES FROM %I', s, r);
            EXECUTE format('ALTER DEFAULT PRIVILEGES IN SCHEMA %I REVOKE ALL ON SEQUENCES FROM %I', s, r);
        END LOOP;
    END LOOP;

    -- REVOKE на таблицу не трогает права на отдельные колонки, их снимаем отдельно.
    FOR rec IN
        SELECT n.nspname, c.relname, a.attname
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE a.attacl IS NOT NULL AND a.attnum > 0 AND NOT a.attisdropped
          AND n.nspname = ANY (schemas || ARRAY['audit', 'public'])
    LOOP
        FOREACH r IN ARRAY runtime || grp LOOP
            EXECUTE format('REVOKE ALL (%I) ON %I.%I FROM %I', rec.attname, rec.nspname, rec.relname, r);
        END LOOP;
    END LOOP;

    -- ---------------------------------------------------------------------------
    -- 1. Группы <схема>_ro / <схема>_rw. Будущие таблицы, созданные владельцем
    --    (миграции выполняются под SET ROLE app_owner), получают те же права сами.
    -- ---------------------------------------------------------------------------
    FOREACH s IN ARRAY schemas LOOP
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO %I, %I', s, s || '_ro', s || '_rw');
        EXECUTE format('GRANT %I TO %I', s || '_ro', s || '_rw');

        EXECUTE format('GRANT SELECT ON ALL TABLES IN SCHEMA %I TO %I', s, s || '_ro');
        EXECUTE format('GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO %I', s, s || '_rw');
        EXECUTE format('GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA %I TO %I', s, s || '_rw');

        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT SELECT ON TABLES TO %I',
                       v_owner, s, s || '_ro');
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT INSERT, UPDATE, DELETE ON TABLES TO %I',
                       v_owner, s, s || '_rw');
        EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO %I',
                       v_owner, s, s || '_rw');
    END LOOP;

    -- ---------------------------------------------------------------------------
    -- 2. Роли сервисов
    -- ---------------------------------------------------------------------------
    EXECUTE format('GRANT auth_rw, core_ro TO %I', v_auth);
    EXECUTE format('GRANT chat_rw, core_ro TO %I', v_chat);

    -- library-svc: каталог документов только читает (select(...) и сырые SELECT). Пишет лишь
    -- пользовательские данные календаря и калькулятора; шаблоны предметов (grade_subject_templates)
    -- наполняет парсер ПУД через админку, для сервиса они только на чтение.
    EXECUTE format('GRANT core_ro TO %I', v_library);
    EXECUTE format('GRANT USAGE ON SCHEMA library TO %I', v_library);
    EXECUTE format('GRANT SELECT ON library.topics, library.documents, library.document_files, '
                   'library.document_relations TO %I', v_library);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON library.planner_tags, library.planner_notes, '
                   'library.planner_note_tags, library.grade_user_templates, library.grade_user_scores TO %I', v_library);
    EXECUTE format('GRANT SELECT ON library.grade_subject_templates TO %I', v_library);

    -- ingest-worker: берёт документ из очереди (SELECT ... FOR UPDATE требует UPDATE хотя бы
    -- на одну колонку), двигает его статусы, пересоздаёт чанки и эмбеддинги. Править
    -- содержимое документа и каталог он не должен.
    EXECUTE format('GRANT core_ro TO %I', v_ingest);
    EXECUTE format('GRANT USAGE ON SCHEMA library TO %I', v_ingest);
    EXECUTE format('GRANT SELECT ON library.documents, library.document_files TO %I', v_ingest);
    EXECUTE format('GRANT UPDATE (ingest_status, ingest_attempts, ingest_started_at, indexed_at, '
                   'ingest_error, ingest_next_attempt_at) ON library.documents TO %I', v_ingest);
    EXECUTE format('GRANT SELECT, INSERT, DELETE ON library.chunks, library.chunk_embeddings TO %I', v_ingest);

    -- Быстрые ответы и ссылки: строки добавляет db-svc, воркер лишь досчитывает вектор.
    -- quick_answers нужна для чтения: признак is_active лежит у родителя варианта. FOR UPDATE
    -- в выборке требует UPDATE хотя бы на одну колонку, поэтому право выдано на колонки вектора.
    EXECUTE format('GRANT SELECT ON library.quick_answers, library.quick_answer_variants, library.links TO %I', v_ingest);
    EXECUTE format('GRANT UPDATE (embedding, embedding_model) ON library.quick_answer_variants, library.links TO %I', v_ingest);

    -- graph-rag-svc: пишет свою схему graph и аналитику rag, а библиотеку только читает.
    -- Чтение библиотеки целиком (library_ro), хотя код нашего экземпляра обращается лишь к
    -- chunks, documents и chunk_embeddings: тем же graph_user подключается экземпляр соседней
    -- команды (graph-rag-svc/README.md, §12.1), и что именно читает он, мы не знаем. Сузить
    -- можно, когда договоримся с ними о составе таблиц.
    EXECUTE format('GRANT graph_rw, core_ro, library_ro TO %I', v_graph);
    EXECUTE format('GRANT USAGE ON SCHEMA rag TO %I', v_graph);
    EXECUTE format('GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA rag TO %I', v_graph);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA rag GRANT SELECT, INSERT ON TABLES TO %I',
                   v_owner, v_graph);

    -- db-svc.
    EXECUTE format('GRANT core_rw, library_rw, graph_ro, chat_ro, rag_ro TO %I', v_dbsvc);
    -- TRUNCATE нужен CSV-импорту в режиме замены (services/csv_import.py). Без CASCADE он
    -- отказывает на таблицах, на которые кто-то ссылается, так что это не «стереть всё».
    EXECUTE format('GRANT TRUNCATE ON ALL TABLES IN SCHEMA core, library TO %I', v_dbsvc);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA core GRANT TRUNCATE ON TABLES TO %I', v_owner, v_dbsvc);
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA library GRANT TRUNCATE ON TABLES TO %I', v_owner, v_dbsvc);
    EXECUTE format('GRANT USAGE ON SCHEMA auth TO %I', v_dbsvc);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON auth.user_profiles TO %I', v_dbsvc);

    -- auth.users: все колонки, кроме password_hash. INSERT не выдаётся: без хеша пароля
    -- строку всё равно не создать, пользователей заводит регистрация.
    SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) INTO cols
    FROM pg_attribute
    WHERE attrelid = 'auth.users'::regclass AND attnum > 0 AND NOT attisdropped
      AND attname <> 'password_hash';
    EXECUTE format('GRANT SELECT (%s), UPDATE (%s) ON auth.users TO %I', cols, cols, v_dbsvc);
    EXECUTE format('GRANT DELETE ON auth.users TO %I', v_dbsvc);

    -- Таблицы с хешами токенов: видны без token_hash, чтобы работали подсчёт и просмотр
    -- зависимостей пользователя; изменять их админке незачем.
    FOREACH r IN ARRAY ARRAY['refresh_tokens', 'email_verifications', 'password_resets'] LOOP
        SELECT string_agg(quote_ident(attname), ', ' ORDER BY attnum) INTO cols
        FROM pg_attribute
        WHERE attrelid = format('auth.%I', r)::regclass AND attnum > 0 AND NOT attisdropped
          AND attname <> 'token_hash';
        EXECUTE format('GRANT SELECT (%s) ON auth.%I TO %I', cols, r, v_dbsvc);
    END LOOP;

    -- Служебные объекты db-svc: журнал задач и журнал действий. Журнал действий —
    -- только вставка и чтение: стереть или поправить след через сервис нельзя.
    EXECUTE 'REVOKE ALL ON SCHEMA public FROM PUBLIC';
    EXECUTE 'GRANT USAGE ON SCHEMA public TO PUBLIC';
    IF to_regclass('public.dbsvc_jobs') IS NOT NULL THEN
        EXECUTE format('REVOKE ALL ON public.dbsvc_jobs FROM %I', v_dbsvc);
        EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON public.dbsvc_jobs TO %I', v_dbsvc);
    END IF;
    IF to_regnamespace('audit') IS NOT NULL THEN
        EXECUTE 'REVOKE ALL ON SCHEMA audit FROM PUBLIC';
        EXECUTE format('REVOKE ALL ON SCHEMA audit FROM %I', v_dbsvc);
        EXECUTE format('GRANT USAGE ON SCHEMA audit TO %I', v_dbsvc);
        IF to_regclass('audit.db_actions') IS NOT NULL THEN
            EXECUTE format('REVOKE ALL ON audit.db_actions FROM %I', v_dbsvc);
            EXECUTE format('GRANT SELECT, INSERT ON audit.db_actions TO %I', v_dbsvc);
        END IF;
    END IF;
END
$sync$;
