# Перенос пайплайна из ноутбука в сервисы — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `graph-rag-svc` отвечает по пайплайну ноутбука (быстрый ответ → гибридный поиск → LLM-реранк → агрегация по документам → ответ), данные берёт из базы, LLM вызывает через прокси `llm-proxy`, эмбеддинги считает `embedding-svc` на multilingual-e5-base; GraphRAG отключён.

**Architecture:** `ingest-worker` разбирает документы по логике ноутбука и досчитывает эмбеддинги чанков, быстрых ответов и ссылок. `graph-rag-svc` на старте строит BM25 из `library.chunks`, плотный поиск делает в pgvector, реранк и ответ идут через `llm-proxy` — nginx, который добавляет ключ, подменяет модель и пересылает запрос на роутер либо в Ollama; режим, модель и адрес роутера читает на лету из `config.json`. Контракт `/generate`, очередь, sinks и аналитика не меняются.

**Tech Stack:** Python 3.11, FastAPI, SQLAlchemy/asyncpg, pgvector, sentence-transformers (multilingual-e5-base), rank-bm25, nltk (Snowball), pypdf, python-docx, openai SDK, httpx, pytest, nginx mTLS-сайдкары.

**Spec:** `main/docs/superpowers/specs/2026-10-27-notebook-pipeline-design.md`. Источник логики — `/home/nedloz/dev/pochemuchnik/MIEM_Last_Stable_Pipeline.ipynb` (ячейки указаны в задачах).

## Global Constraints

- Модель эмбеддингов: `intfloat/multilingual-e5-base`, размерность **768**, префиксы `passage: ` / `query: `.
- Роутер: `router.model = "qwen/qwen3.5-9b"` в `config.json` по умолчанию (`graph-rag-svc` шлёт `model: "default"`), температура реранка 0.0, ответа 0.3, лимиты токенов 750 / 1100 / 150 (переписывание).
- Пороги: быстрый ответ — RRF ≥ 0.04 и косинус ≥ 0.83, веса RRF 1.5 (dense) / 1.0 (BM25), k=60; поиск чанков — веса 1.0 / 0.9, top-60 + top-60 → top-40; реранк 28 кандидатов, текст до 1100 символов, top-18; ссылки — top-3, порог 0.75; контекст до 9 чанков и 18000 символов; веса документа 1/0.55/0.30/0.15.
- Чанки: до 1600 символов, overlap — последний абзац ≤ 350 символов, минимум 80 символов.
- Контракт `/generate` (режимы `sync`/`ws_bridge`) не меняется.
- Коммиты (CLAUDE.md): сначала коммит в сабмодуле, затем отдельный коммит в `main` с обновлением ссылки; ветка `dev`; сообщение — короткое описание по-русски в одну строку (без номера, если задачи в Jira нет); **никаких `Co-Authored-By` и строк «Generated with…»**; в индекс только свои правки; не пушить.
- Не запускать стек с профилем `llm` и `embedding-svc`; SQL и сервисы проверять на одноразовых контейнерах (`docker run --rm`), не поднимая основной compose.
- Ключ роутера (`ROUTER_KEY`) хранится только в окружении `llm-proxy` (`main/.env`, в git не попадает); в `config.json` ключей нет.

## Review Focus

1. Нет ни одного проиндексированного документа: вопрос не падает, пользователь получает честное «нет материалов» (Task 8).
2. `llm-proxy` недоступен или upstream отвечает 5xx: ошибка уходит в `sink.error`, воркер не зависает (Task 9).
3. Реранкер вернул не-JSON или чужие id: порядок берётся по RRF (Task 8).
4. Ссылка с `http://` не теряется; пустые и повторные строки Excel не плодят дубли, повторный импорт идемпотентен (Tasks 5, 6).
5. После смены размерности в базе не остаётся векторов 1024 и документы переиндексируются (Task 1).
6. Английский вопрос при русских документах получает английский ответ; переписанный запрос не меняет язык ответа (Task 8).

---

### Task 1: Миграция 011 — размерность 768, быстрые ответы, ссылки

**Files:**
- Create: `infra/db/migrations/011_notebook_pipeline.sql`
- Modify: `infra/db/init/init.sql` (таблицы `library.quick_answers`, `library.quick_answer_variants`, `library.links`, триггеры), `.env.example` (`EMBEDDING_DIM=768`, `EMBEDDER_MODEL_NAME=intfloat/multilingual-e5-base`)
- Test: `tests/test_migration_011.sh`

**Interfaces:**
- Produces (таблицы, схема `library`):
  - `quick_answers(id uuid pk, question text unique not null, answer text not null, source text, is_active bool default true, created_at, updated_at)`
  - `quick_answer_variants(id uuid pk, quick_answer_id uuid → quick_answers on delete cascade, text text not null, embedding vector(768) null, embedding_model text null, unique(quick_answer_id, text))`
  - `links(id uuid pk, description text not null, url text unique not null, embedding vector(768) null, embedding_model text null, is_active bool default true)`
  - `pg_notify('ingest_jobs', …)` при вставке/обновлении строки с `embedding IS NULL` в `quick_answer_variants` и `links`.

- [ ] **Step 1: Write the failing test.** `tests/test_migration_011.sh` поднимает `pgvector/pgvector:pg16` с `--rm`, применяет `init.sql` с `-v embedding_dim=1024` и миграции 002–010, вставляет один документ `indexed` с чанком и вектором, применяет 011 и проверяет: `core.vector_column_dimension('library.chunk_embeddings','embedding') = 768`; `count(*) FROM library.chunk_embeddings = 0`; документ стал `pending` с `ingest_attempts = 0`; три новые таблицы существуют; `graph.entities.name_embedding` остался 1024; повторный запуск 011 проходит без ошибок.
- [ ] **Step 2: Run** `bash tests/test_migration_011.sh`. Expected: FAIL (нет файла миграции).
- [ ] **Step 3: Write `011_notebook_pipeline.sql`** (идемпотентно): очистить `library.chunk_embeddings`, `ALTER COLUMN embedding TYPE vector(768)`, пересоздать векторный индекс (имя и тип смотреть в `init.sql`), вернуть `indexed`-документы в `pending`, создать три таблицы и триггеры. Отразить то же в `init.sql` для чистой базы.
- [ ] **Step 4: Run** тот же скрипт. Expected: PASS.
- [ ] **Step 5: Commit** в `main`: `git add infra/db tests/test_migration_011.sh .env.example && git commit -m "Миграция 011: векторы 768, быстрые ответы и ссылки"`.

---

### Task 2: embedding-svc — multilingual-e5-base и поле `kind`

**Files:**
- Modify: `services/embedding-svc/app/main.py`, `services/embedding-svc/.env.example`
- Test: `services/embedding-svc/tests/test_prefix.py`

**Interfaces:**
- Produces: `POST /embed` принимает `{"texts": [...], "normalize": bool, "kind": "passage" | "query"}` (по умолчанию `passage`); ответ как раньше. Функция `apply_prefix(texts: list[str], kind: str, model_name: str) -> list[str]` ставит `"passage: "`/`"query: "` только если `"e5"` входит в имя модели (в нижнем регистре), иначе возвращает тексты без изменений.

- [ ] **Step 1: Write the failing tests:** `apply_prefix(["а"], "query", "intfloat/multilingual-e5-base") == ["query: а"]`; `kind="passage"` → `["passage: а"]`; `apply_prefix(["а"], "query", "BAAI/bge-m3") == ["а"]`; невалидный `kind` в модели запроса даёт 422.
- [ ] **Step 2: Run** `pytest services/embedding-svc/tests/test_prefix.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement** `apply_prefix` и поле `kind: Literal["passage","query"] = "passage"` в `EmbedRequest`; вызвать префиксирование до `model.encode`. Лимиты по длине считать по исходным текстам. Сменить `EMBEDDER_MODEL_NAME` в `.env.example` на e5.
- [ ] **Step 4: Run** тесты. Expected: PASS.
- [ ] **Step 5: Commit** в сабмодуле `embedding-svc`: `Модель multilingual-e5-base и префиксы query/passage`; затем коммит обновления ссылки в `main`.

---

### Task 3: llm-proxy — nginx + njs, настройки на лету

**Files:**
- Create: `infra/llm-proxy/default.conf.template`, `infra/llm-proxy/llm.js` (njs), `infra/llm-proxy/config.default.json`, `infra/llm-proxy/entrypoint.sh` (создаёт `config.json` из умолчаний, если его нет на томе), `infra/llm-proxy/README.md`, `infra/llm-proxy/tests/proxy_e2e.sh`
- Modify: `docker-compose.yml` (сервис `llm-proxy`: `nginx:1.27-alpine`, том `llm_proxy_config:/etc/llm-proxy`, переменная окружения `ROUTER_KEY`, директива `env ROUTER_KEY;` в main-контексте nginx), `docker-compose.mtls.yml` (серверный сертификат и политика по CN — по образцу `ollama-mtls`/`ollama-certs`; клиентский сертификат прокси для режима `ollama`), `infra/mtls/ollama.conf` (пускать CN `llm-proxy` на `/v1/chat/completions`), `.env.example` (`ROUTER_KEY=`)

**Interfaces:**
- `config.json`: `{"mode": "router"|"ollama", "router": {"url": str, "model": str}, "ollama": {"url": str, "model": str}}`; умолчания в `config.default.json` — `mode="router"`, `router.url="https://api.polza.ai/v1"`, `router.model="qwen/qwen3.5-9b"`, `ollama.url="https://ollama:8443/v1"`, `ollama.model=""`.
- Produces: `llm-proxy` принимает `POST /v1/chat/completions` (OpenAI-формат, `model` любой) на `:8080` (без mTLS) либо `:8443` (с оверлеем mTLS: только CN `graph-rag-svc`). По `mode` из актуального `config.json`: запрос уходит на `<url>/chat/completions` выбранного режима с `model` режима; в `router` — с `Authorization: Bearer $ROUTER_KEY`, в `ollama` — без ключа. Любой другой путь/метод → 403; `GET /healthz` → 200.
- njs (`llm.js`): `function loadConfig(r) -> object` — читает и валидирует `config.json`, при ошибке возвращает последнюю корректную конфигурацию и пишет `r.error(...)`; `function rewriteBody(r) -> string` — подменяет `model`, остальные поля сохраняет.

- [ ] **Step 1: Spike (выбросить после проверки).** Проверить в одноразовом контейнере, что на `nginx:1.27-alpine` njs позволяет (а) переписать тело запроса и выбрать upstream по содержимому файла, (б) пропустить SSE-ответ порциями без буферизации. Если потоковая передача через njs невозможна, остановиться и сообщить, не переходя к усложнённой схеме.
- [ ] **Step 2: Write the failing test** `infra/llm-proxy/tests/proxy_e2e.sh` на одноразовых контейнерах (заглушка upstream: эхо заголовков и тела, SSE из трёх событий). Проверить: `mode=router` — путь `/v1/chat/completions` → `<router.url>/chat/completions`, `model: "default"` заменён на `router.model`, `messages`/`temperature`/`max_tokens`/`stream` не изменены, `Authorization` заменён ключом, чужой `Bearer client` не доходит; `mode=ollama` — другой upstream и модель, без `Authorization`; **горячая смена**: запись нового `config.json` (через временный файл и `mv`) меняет режим, модель и `router.url` со следующего же запроса без перезапуска контейнера; битый JSON не ломает работу — запросы идут по последней корректной конфигурации, в логе ошибка; отсутствие корректного файла с самого старта → 503; SSE приходит порциями (первое событие раньше конца); `GET /v1/models` и `POST /v1/embeddings` → 403; `/healthz` → 200; в `docker logs llm-proxy` нет ключа и тел запросов.
- [ ] **Step 3: Run** `bash infra/llm-proxy/tests/proxy_e2e.sh`. Expected: FAIL.
- [ ] **Step 4: Implement** шаблон, `llm.js` и `entrypoint.sh`: `js_import`, `js_set` для выбора upstream, `resolver 127.0.0.11` и `proxy_pass` с переменной, `proxy_ssl_server_name on`, `Host` по upstream, `proxy_buffering off`, `proxy_read_timeout 180s`, `client_max_body_size 1m`, `access_log` без заголовков и тел.
- [ ] **Step 5: Run** тот же скрипт и `docker compose config -q`. Expected: PASS. Ollama и модель не запускаются.
- [ ] **Step 6: Commit** в `main`: `Добавлен llm-proxy: nginx с njs, настройки на лету`.

---

### Task 4: ingest-worker — парсинг и чанкинг по ноутбуку

**Files:**
- Create: `services/ingest-worker/app/notebook_parsing.py`, `services/ingest-worker/app/notebook_chunker.py`, `services/ingest-worker/tests/test_notebook_chunking.py`
- Modify: `services/ingest-worker/app/main.py` (шаги 4–6 в `process_one_document`, модель `Document` получает `category`), `services/ingest-worker/app/parsers.py` (оставить `get_content*`, удалить `parse_*`), `services/ingest-worker/app/chunker.py` (удалить), `requirements.txt` (`pypdf`, убрать `PyMuPDF`, если больше не нужен)

**Interfaces:**
- `notebook_parsing.clean_text(text: str | None) -> str` — ячейка 9.
- `notebook_parsing.extract_blocks(content: bytes, doc_type: str) -> list[dict]` — `doc_type ∈ {"pdf","docx","txt"}`; блок `{"section": str, "kind": str, "text": str}`; DOCX через `Document(io.BytesIO(content))`, таблицы строками `«Заголовок: значение | …»`, PDF через `pypdf` (раздел «Страница N»), TXT с `#`-заголовками.
- `notebook_chunker.split_long_text(text: str, max_chars: int = 1400) -> list[str]` и `build_document_chunks(blocks: list[dict], max_chars: int = 1600) -> list[dict]` → `[{"chunk_index": int, "section": str, "text": str}]` — ячейка 11 без привязки к `manifest`.
- `notebook_chunker.embedding_text(title: str, category: str, section: str, text: str) -> str` → `"Название документа: {title}\nКатегория: {category}\nРаздел: {section}\nТекст: {text}"` (префикс `passage:` ставит `embedding-svc`).

- [ ] **Step 1: Write the failing tests:** `clean_text` убирает markdown-ссылку `[a](http://x)` → `a`, cookie-мусор и `\xa0`; `split_long_text` режет по предложениям, не превышая лимит, а слишком длинное предложение — жёстко; `build_document_chunks` не склеивает разные `section`, переносит последний абзац ≤ 350 символов в следующий чанк, отбрасывает чанк короче 80 символов, нумерует с 0; `extract_blocks` на сгенерированном DOCX с заголовком и таблицей 2×2 возвращает блок-заголовок и строку `«Колонка: значение»`; `embedding_text` — точная строка по формату.
- [ ] **Step 2: Run** `pytest services/ingest-worker/tests/test_notebook_chunking.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement** модули переносом логики ячеек 9 и 11. В `process_one_document` заменить парсинг/нарезку: `extract_blocks` в `asyncio.to_thread`, затем `build_document_chunks`; в `library.chunks` писать `section_path = section`, `token_count` — число слов, `metadata_json = {"kind": "notebook-v1"}`; текст для эмбеддинга строить `embedding_text(doc.title, doc.category, section, text)`, вызов `_embed(texts)` оставить, добавив `kind="passage"` в тело запроса к `embedding-svc`. Очередь, повторы, `LISTEN/NOTIFY`, метрики и mTLS не менять.
- [ ] **Step 4: Run** весь `pytest services/ingest-worker/tests -v`. Expected: PASS (включая `test_business_metrics.py`).
- [ ] **Step 5: Commit** в сабмодуле `ingest-worker`: `Парсинг и чанкинг по пайплайну ноутбука`; затем `main`.

---

### Task 5: ingest-worker — эмбеддинги быстрых ответов и ссылок

**Files:**
- Create: `services/ingest-worker/app/aux_index.py`, `services/ingest-worker/tests/test_aux_index.py`
- Modify: `services/ingest-worker/app/main.py` (главный цикл вызывает `embed_pending_aux()` после пустой очереди документов)

**Interfaces:**
- Consumes: `_embed(texts: list) -> tuple[list, str]` из `main.py` (с `kind="passage"`), таблицы из Task 1.
- Produces: `async def embed_pending_quick_answers(limit: int = 256) -> int` и `async def embed_pending_links(limit: int = 256) -> int`: выбирают строки с `embedding IS NULL AND is_active`, считают векторы батчем, пишут `embedding` и `embedding_model`, возвращают число обработанных. Нормализация текста варианта — как в ячейке 31: нижний регистр, удаление всего кроме букв, цифр и пробелов, `strip()`; пустые пропускаются.

- [ ] **Step 1: Write the failing tests** (БД и `_embed` подменены): строки с `embedding IS NULL` получают вектор и имя модели; уже посчитанные не трогаются; при ошибке `embedding-svc` ничего не записывается и исключение пробрасывается; вызов на пустой выборке возвращает 0 и не обращается к `_embed`.
- [ ] **Step 2: Run** `pytest services/ingest-worker/tests/test_aux_index.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement** модуль и подключить в главный цикл: после того как `process_one_document()` вернул `False`, вызвать обе функции, повторять пока обе возвращают > 0. Метрику `JOBS` не трогать; добавить счётчик в `metrics.py` по образцу `CHUNKS_CREATED`.
- [ ] **Step 4: Run** `pytest services/ingest-worker/tests -v`. Expected: PASS.
- [ ] **Step 5: Commit** в `ingest-worker`: `Эмбеддинги быстрых ответов и ссылок`; затем `main`.

---

### Task 6: db-svc — импорт Excel и ссылок, отключение маршрутов графа

**Files:**
- Create: `services/db-svc/app/services/quick_answers_import.py`, `services/db-svc/tests/test_quick_answers_import.py`
- Modify: `services/db-svc/app/routes/db.py` (два эндпоинта импорта), `services/db-svc/app/main.py` (не подключать `routes/graph.py`), `services/db-svc/requirements.txt` (`openpyxl`)

**Interfaces:**
- `parse_quick_answers_xlsx(data: bytes) -> list[dict]` → `[{"question": str, "answer": str, "variants": list[str]}]`; колонки находятся по заголовкам `Основной вопрос`, `Ответ на русском`, `Варианты вопроса на русском`; варианты — по переносам строк и `;`, `strip`, без пустых и дублей; основной вопрос также входит в `variants`.
- `parse_links_txt(text: str) -> list[dict]` → `[{"description": str, "url": str}]`; URL — подстрока от первого `http://` или `https://`, описание — всё до неё без хвостовой точки и пробелов; строки без URL пропускаются.
- `async def import_quick_answers(session, rows: list[dict]) -> dict` и `async def import_links(session, rows: list[dict]) -> dict`: upsert по `question` и по `url`; для существующего ответа с изменившимся вопросом-вариантом — добавить новые варианты, у изменённого `answer` обнулить `embedding` вариантов (триггер разбудит воркер); возвращают `{"created": int, "updated": int, "skipped": int}`.
- Эндпоинты `POST /api/db/library/quick-answers/import` (multipart `.xlsx`) и `POST /api/db/library/links/import` (multipart `.txt`) — права как у остальных импортов.

- [ ] **Step 1: Write the failing tests:** на реальной структуре файла (3 колонки, варианты через `\n`) получаются нужные списки; строка с `http://www.hse.ru/dormitory/` попадает в ссылки; строка без URL пропускается; повторный импорт того же файла даёт `created=0, updated=0`; пустая строка Excel не создаёт запись.
- [ ] **Step 2: Run** `pytest services/db-svc/tests/test_quick_answers_import.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement** парсеры, upsert и эндпоинты; отключить роутер графа (импорт и `include_router` закомментировать с пометкой «GraphRAG отключён, см. спецификацию 2026-10-27»).
- [ ] **Step 4: Run** тесты. Expected: PASS.
- [ ] **Step 5: Commit** в `db-svc`: `Импорт быстрых ответов и ссылок, отключены маршруты графа`; затем `main`.

---

### Task 7: graph-rag-svc — отключение GraphRAG

**Files:**
- Modify: `services/graph-rag-svc/app/main.py`, `app/core/startup_checks.py` (`_VECTOR_COLUMNS` → только `("library.chunk_embeddings", "embedding")`), `app/core/config.py` (`graph_build_api_enabled = False`, убрать `judge_mode`), `app/api/http.py` (`/ping` без `judge_mode`), `app/generation/job_queue.py` (временно не менять вызов — переключение в Task 9)
- Modify (только шапка `DISABLED`): `app/graph/*`, `app/ontology/*`, `app/api/graph_admin.py`, `app/retrieval/graph_retriever.py`, `cli/*`
- Test: `services/graph-rag-svc/tests/test_graph_disabled.py`

**Interfaces:**
- Produces: приложение стартует без импорта `app.graph`/`app.ontology`/`app.api.graph_admin`; маршрутов `/internal/graph/*` нет (404).

- [ ] **Step 1: Write the failing tests:** после `import app.main` в `sys.modules` нет `app.graph.store`, `app.ontology.extractor` и `app.api.graph_admin`; `GET /internal/graph/build` → 404; `startup_checks._VECTOR_COLUMNS` не содержит `graph.*`.
- [ ] **Step 2: Run** `pytest services/graph-rag-svc/tests/test_graph_disabled.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement.** Каждому модулю графа добавить первой строкой docstring: `"""DISABLED: GraphRAG отключён (спецификация 2026-10-27-notebook-pipeline-design). Код не поддерживается и не вызывается."""`. В `main.py` убрать подключение роутера и `release_orphaned_runs`. `orchestrator.py` пока не трогать — он импортирует `graph_retriever`; импорт убирается в Task 9, поэтому до неё `judge_mode` оставить в конфиге.
- [ ] **Step 4: Run** тесты. Expected: PASS (если упал `orchestrator`-импорт, перенести убирание `judge_mode` в Task 9).
- [ ] **Step 5: Commit** в `graph-rag-svc`: `Отключён GraphRAG`; затем `main`.

---

### Task 8: graph-rag-svc — модули пайплайна ноутбука

**Files:**
- Create: `services/graph-rag-svc/app/pipeline/{__init__,tokenize,hybrid,rerank,context,quick_answers,links,rewrite,prompts,index,service}.py`, `services/graph-rag-svc/tests/pipeline/test_*.py`
- Modify: `services/graph-rag-svc/requirements.txt` (`rank-bm25`, `nltk`, `numpy`)

**Interfaces** (все функции чистые, кроме помеченных `async` — те получают зависимости параметрами):
- `tokenize.tokenize(text: str) -> list[str]` — ячейка 13 (слова `[A-Za-zА-Яа-яЁё0-9]+`, длина > 2, Snowball ru).
- `hybrid.rrf_merge(dense: list[tuple[int, float]], lexical: list[tuple[int, float]], dense_weight: float, lexical_weight: float, k: int = 60, top_k: int | None = None) -> list[tuple[int, float]]` — ячейка 21 (поиск чанков: 1.0/0.9, top 40) и ячейка 33 (быстрые ответы: 1.5/1.0).
- `rerank.parse_json_response(text: str) -> dict` — ячейка 19. `async rerank.rerank(llm: LlmClient, question: str, candidates: list[Candidate], top_n: int = 18) -> tuple[list[Candidate], int | None]` — ячейка 23; любой сбой разбора → первые `top_n` кандидатов с `rerank_score = 0.0`.
- `Candidate` (dataclass в `index.py`): `idx: int, chunk_id: uuid.UUID, document_id: uuid.UUID, chunk_index: int, title: str, category: str, section: str, text: str, rrf_score: float = 0.0, rerank_score: float = 0.0`.
- `context.aggregate_documents(ranked: list[Candidate]) -> list[dict]`, `context.select_context(ranked: list[Candidate], neighbours: Callable[[uuid.UUID, int], Candidate | None], max_chunks: int = 9) -> tuple[list[Candidate], list[dict]]`, `context.build_context(selected: list[Candidate], max_chars: int = 18000) -> str` — ячейка 25.
- `index.KnowledgeIndex`: `async load(session_factory) -> None` (читает проиндексированные чанки `ingest_status='indexed'` вместе с `title`, `category`, `section_path`, строит BM25 по `embedding_text`-строке из Task 4), `needs_refresh(signature: tuple[int, str | None]) -> bool`, `async refresh_if_stale(session_factory) -> bool` (сигнатура — `count(*)` и `max(indexed_at)`), `lexical_search(question: str, k: int) -> list[tuple[int, float]]`, `async dense_search(session, query_vector: list[float], model: str, k: int) -> list[tuple[int, float]]` (pgvector, косинус, только `embedding_model == model`), `neighbour(document_id, chunk_index) -> Candidate | None`.
- `quick_answers.find_quick_answer(...)`: `async def find_quick_answer(session, question: str, query_vector: list[float], model: str, rrf_threshold: float = 0.04, cosine_threshold: float = 0.83) -> QuickAnswer | None` (`QuickAnswer(answer: str, question: str, rrf_score: float)`); dense по `quick_answer_variants`, BM25 по ним же (раздельный индекс, не `bm25` чанков), вопрос предварительно нормализуется как в Task 5.
- `links.find_links(session, query_vector, model, top_k: int = 3, threshold: float = 0.75) -> list[tuple[str, str]]` — `(description, url)`.
- `rewrite.async contextualize_question(llm, question: str, history: list[HistoryMessage]) -> str` — ячейка 35 (последние 10 реплик, `max_tokens=150`; пусто → исходный вопрос).
- `prompts.FINAL_SYSTEM: str` — ячейки 27 и 36 в одном тексте, правило языка один раз; `prompts.language_rule(question: str) -> str`; `prompts.build_messages(question: str, history: list[HistoryMessage], context: str, links: list[tuple[str, str]]) -> list[dict]` — язык по исходному вопросу, история ≤ 6 реплик, вывод пустого контекста «релевантные материалы не найдены».
- `service.async run_retrieval(job, llm, index, session_factory) -> RetrievalResult` — склеивает шаги; `RetrievalResult(quick_answer: QuickAnswer | None, messages: list[dict], selected: list[Candidate], links: list, rerank_tokens: int | None, query_model: str, retrieval_ms: float)`.

- [ ] **Step 1: Write the failing tests:** `tokenize("Пересдачи экзаменов")` стеммит и отбрасывает слова ≤ 2 символов; `rrf_merge` объединяет два списка с весами и режет по `top_k`, одинаковый индекс суммируется; `parse_json_response` разбирает обёртку ```json и текст вокруг, на мусоре бросает `ValueError`; `rerank` с фейковым `llm`: валидный JSON меняет порядок, не-JSON и чужие id → порядок по RRF, дубли id игнорируются; `aggregate_documents` даёт веса 1/0.55/0.30/0.15 по четырём лучшим; `select_context`: второй документ берётся только при `score ≥ 0.6·первого` и `≥ 0.35`, соседи `±1` добавляются, итог ≤ 9; `build_context` не превышает 18000 символов; `find_quick_answer` возвращает `None`, если ниже любого порога, и ответ — если оба пройдены; `find_links` не теряет `http://`-ссылку и режет по порогу; `build_messages` для вопроса «How do I get a certificate?» при русском контексте содержит «на английском»; пустой индекс → `run_retrieval` возвращает результат с пустым `selected` без исключения.
- [ ] **Step 2: Run** `pytest services/graph-rag-svc/tests/pipeline -v`. Expected: FAIL.
- [ ] **Step 3: Implement** модули переносом логики из указанных ячеек; параметры — из Global Constraints. Реранк и переписывание вызывают `llm.chat(messages, temperature, max_tokens)` (Task 9). Слабо определённые детали (структура SQL для dense-поиска, форма кэша индекса) выбирает исполнитель; `app/pipeline/*` не импортирует ничего из `app.graph`/`app.ontology`.
- [ ] **Step 4: Run** тесты. Expected: PASS.
- [ ] **Step 5: Commit** в `graph-rag-svc`: `Модули пайплайна ноутбука: гибридный поиск, реранк, контекст`; затем `main`.

---

### Task 9: graph-rag-svc — подключение пайплайна и клиент llm-proxy

**Files:**
- Create: `services/graph-rag-svc/app/generation/llm_client.py`, `services/graph-rag-svc/tests/test_process_job.py`
- Modify: `app/generation/job_queue.py` (`process_job`), `app/main.py` (загрузка индекса на старте, фоновое обновление), `app/core/config.py` (`llm_base_url = "http://llm-proxy:8080/v1"`, `llm_model = "default"`, `index_refresh_interval_sec = 60`; удалить `llm_provider`, `openai_*`, `ollama_*`, `transformers_model`, `device`, `judge_mode`), `app/api/http.py` (`/ping`: `llm_base_url`), `Dockerfile` (убрать `WITH_LOCAL_LLM`), `.env.example`
- Delete: `app/retrieval/{judge,orchestrator,vector_retriever,context_assembler}.py`, `app/generation/llm_backends.py`, `requirements-local.txt`; из `app/generation/prompt_builder.py` убрать неиспользуемое, `injection_defense.py` оставить (используется для лога подозрительных чанков)
- Modify (метаданные): `app/retrieval/graph_retriever.py` — убрать импорты удалённых модулей и оставить с пометкой `DISABLED`

**Interfaces:**
- `LlmClient(base_url: str, model: str)` с `async chat(messages: list[dict], temperature: float, max_tokens: int) -> tuple[str, int | None]` и `async stream(messages: list[dict], usage: dict | None = None, temperature: float = 0.3, max_tokens: int = 1100) -> AsyncIterator[dict]` — события `{"type": "chunk"|"error", "content": str}` ровно как у прежнего `stream_model`. Клиент — `openai.AsyncOpenAI(base_url=…, api_key="unused", http_client=httpx.AsyncClient(**httpx_kwargs()), timeout=settings.llm_request_timeout_sec)`; `stream` просит `stream_options={"include_usage": True}` и пишет `usage` в переданный словарь. Это сжатая версия `_stream_openai` из `llm_backends.py`.
- `process_job` в порядке: `sink.started` → `run_retrieval` → если есть `quick_answer`: `sink.chunk(answer)` и `sink.completed` без вызова LLM → иначе `llm.stream(result.messages)` → `sink.completed(usage)`; ошибка ретривала → `RETRIEVAL_FAILURES.inc()`, запись в `retrieval_log`, `RuntimeError("Не удалось получить контекст для ответа")` как раньше; `job.rag` заполняется ключами, которые читают `retrieval_log.record` и `sinks` (сверить с `context_assembler.assemble` перед удалением и сохранить их).

- [ ] **Step 1: Write the failing tests** (фейковые `LlmClient`, `KnowledgeIndex`, `Sink`): быстрый ответ уходит без вызова `llm.stream`; обычный вопрос стримит чанки и завершает с `usage`; `llm.stream` отдал `{"type":"error"}` → `sink.error`, в `retrieval_log` статус `error`; исключение в `run_retrieval` → `RuntimeError` с прежним текстом; отмена посреди стрима → `sink.cancelled`; недоступный `llm-proxy` (исключение при подключении) не вешает воркер и доходит до `sink.error`.
- [ ] **Step 2: Run** `pytest services/graph-rag-svc/tests/test_process_job.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement.** В `startup_event`: `verify_embedding_setup()` → `await index.load(SessionLocal)` → фоновая задача `refresh_if_stale` каждые `index_refresh_interval_sec`. Остановка задачи в `shutdown_event`. Пустой индекс — предупреждение в лог, сервис стартует.
- [ ] **Step 4: Run** `pytest services/graph-rag-svc/tests -v`. Expected: PASS (включая `test_metrics.py`, `test_business_metrics.py`).
- [ ] **Step 5: Commit** в `graph-rag-svc`: `Пайплайн ноутбука в process_job, LLM через llm-proxy`; затем `main`.

---

### Task 10: compose, mTLS, документация, проверка на одноразовых контейнерах

**Files:**
- Modify: `docker-compose.yml` (`graph-rag-svc` → `LLM_BASE_URL`, зависимость от `llm-proxy`, убрать `OLLAMA_MODEL`, `WITH_LOCAL_LLM`; `EMBEDDING_DIM=768`), `.env.example`, `services/README.md` (карта сервисов, путь вопроса, состояние), `services/graph-rag-svc/README.md` (раздел о пайплайне и отключённом графе), `infra/llm-proxy/README.md`
- Test: `tests/test_notebook_pipeline_flow.py`

**Interfaces:**
- Consumes: всё выше. Produces: сквозная проверка «документ → чанки → вопрос → ответ».

- [ ] **Step 1: Write the failing flow test** (по образцу `tests/test_chat_flow_fixed`): на одноразовых контейнерах `pgvector/pgvector:pg16` + заглушки `embedding-svc` (детерминированные векторы 768) и upstream для `llm-proxy` (фиксированные ответы); загрузить один маленький `.txt`-документ и одну строку быстрых ответов; убедиться, что (а) вопрос из быстрых ответов возвращает готовый ответ без обращения к LLM-заглушке, (б) вопрос по документу возвращает ответ с источником, (в) вопрос не по теме проходит через guardrail-промпт.
- [ ] **Step 2: Run** `python tests/test_notebook_pipeline_flow.py`. Expected: FAIL.
- [ ] **Step 3: Update compose, mTLS и README** по перечню выше; `docker compose config` проходит без ошибок; в README графрага явно сказано, что граф отключён и как включить его обратно (история git + пометки `DISABLED`).
- [ ] **Step 4: Run** `docker compose config -q` и flow-тест. Expected: PASS. Основной стек, `embedding-svc` и профиль `llm` при этом не запускаются.
- [ ] **Step 5: Commit** в `main`: `Compose, mTLS и документация для пайплайна ноутбука`.

---

### Task 11: db-svc — страница «Настройки проекта» (только чтение)

**Files:**
- Create: `services/db-svc/app/routes/project_settings.py`, `services/db-svc/tests/test_project_settings.py`
- Modify: `services/db-svc/app/main.py` (подключить роутер), `services/db-svc/app/static/index.html` (раздел «Настройки проекта»), `docker-compose.yml` (db-svc монтирует том `llm_proxy_config` только на чтение в `/etc/llm-proxy` и получает `EMBEDDER_MODEL_NAME`, `EMBEDDING_DIM` из тех же переменных, что и остальные сервисы)

**Interfaces:**
- `read_llm_config(path: str = "/etc/llm-proxy/config.json") -> dict` — читает и валидирует файл; при отсутствии или порче возвращает `{"mode": "unknown", "model": None}`.
- `GET /api/db/settings/project` (права как у остальных админских маршрутов) → `{"llm": {"mode": "router"|"ollama"|"unknown", "model": str | null}, "embeddings": {"model": str, "dimension": int}, "graphrag": {"enabled": false}, "pipeline": "notebook-v1"}`. Модель LLM берётся из секции действующего режима. Ключей и URL роутера в ответе нет.
- Раздел в `index.html` показывает эти значения текстом, без элементов управления.

- [ ] **Step 1: Write the failing tests** (временный `config.json`): `mode="router"` → в ответе `router.model`; `mode="ollama"` → `ollama.model`; после перезаписи файла следующий запрос возвращает новые значения (без перезапуска); отсутствующий или битый файл → `mode="unknown"`, статус 200; в JSON нет подстрок `url` и значения `ROUTER_KEY`; без админских прав → 403 (как у соседних маршрутов).
- [ ] **Step 2: Run** `pytest services/db-svc/tests/test_project_settings.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement** маршрут и раздел страницы: стиль и навигация — как у существующих разделов `index.html`.
- [ ] **Step 4: Run** `pytest services/db-svc/tests -v`. Expected: PASS.
- [ ] **Step 5: Commit** в `db-svc`: `Страница настроек проекта в админке (только чтение)`; затем `main`.

---

## Self-review

- **Покрытие спецификации:** E5 и `kind` — Task 2; миграция 768 и новые таблицы — 1; парсинг/чанкинг по ноутбуку — 4; эмбеддинги Excel/ссылок — 5; импорт в базу — 6; отключение графа (graph-rag-svc и db-svc) — 7 и 6; пайплайн — 8–9; `llm-proxy` — 3; compose/mTLS/README — 10; страница настроек в админке — 11.
- **Типы:** `Candidate`, `KnowledgeIndex`, `LlmClient`, `QuickAnswer`, `RetrievalResult` определены в Task 8/9 и используются под теми же именами; `_embed(..., kind)` из Task 4 используется в Task 5.
- **Известные оставленные исполнителю решения:** SQL dense-поиска, форма кэша индекса, имя векторного индекса в миграции, подбор прав эндпоинтов импорта, пометка даты у `DISABLED`.
- **Пропорция:** план задаёт интерфейсы и проверки; тела функций определяются ячейками ноутбука.
