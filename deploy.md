# Развёртывание «Почемучника»

Что нужно, чтобы поднять проект с нуля. Подробности по каждому сервису — в его README
(`services/<имя>/README.md`), карта сервисов — `services/README.md`.

> Стек целиком ещё не прогонялся end-to-end: контейнеры поднимаются, вход в админку проверен,
> но путь «вопрос → ответ» и сборка графа на реальных данных не проверялись.

## 1. Что нужно на машине

| Что | Зачем |
| :-- | :-- |
| Docker Engine + Compose v2 (**системный движок, не Docker Desktop**) | Docker Desktop на Linux держит свою VM, в которую GPU не пробрасывается (`failed to discover GPU vendor from CDI`) |
| NVIDIA GPU + драйвер + `nvidia-container-toolkit` | `embedding-svc` резервирует GPU (модель `intfloat/multilingual-e5-base`), `ollama` (резерв, профиль `llm`) тоже |
| Git ≥ 2.13 | В проекте сабмодули |
| ~15 ГБ свободного диска | Образы, веса e5 (~1.1 ГБ), модель ollama (если включён профиль `llm`), тома postgres/minio |
| Доступ в интернет | Скачивание весов с Hugging Face при первом запуске; вызовы внешнего LLM-роутера из `llm-proxy` |
| Почтовый ящик сервиса | Письма подтверждения и сброса пароля, см. раздел 6 |

pnpm и Node на хосте не нужны: фронтенд собирается внутри образа `nginx` (`infra/nginx/Dockerfile`).

Без GPU стек не запустится в таком виде: не включайте профиль `llm` (`COMPOSE_PROFILES`), а для
`embedding-svc` уберите блок `deploy.resources` в `docker-compose.yml` (модель пойдёт на CPU,
но медленно).

## 2. Получение кода

```bash
git clone --recurse-submodules git@github.com:nedloz/pochemuchnic-miem-prj.git
cd pochemuchnic-miem-prj
git checkout dev
git submodule update --init --recursive
```

Вся работа ведётся в ветке `dev` каждого репозитория. У `services/crawler-svc` и `frontend`
чужие репозитории: читать их можно, писать нельзя.

## 3. Конфигурация

### 3.1. Файлы `.env`

```bash
cp .env.example .env
for s in services/*/; do [ -f "$s/.env.example" ] && cp -n "$s/.env.example" "$s/.env"; done
```

`.env` в git не попадают. Корневой `.env` задаёт порты, пароли БД, MinIO, модель эмбеддингов;
`services/<имя>/.env` — настройки самих сервисов.

### 3.2. Межсервисная аутентификация

Статических межсервисных токенов нет. Вызывающего подтверждает клиентский сертификат (§ PKI),
а имя из него прокси-сайдкар получателя передаёт приложению в `X-Caller-Identity`. Заголовку
верят только от loopback. Режим задаёт `INTERNAL_AUTH_MODE`: `mtls` (по умолчанию в коде и в
`docker-compose.mtls.yml`) или `insecure`. В базовом `docker-compose.yml` без PKI стоит
`insecure`: внутренние вызовы не аутентифицируются, для локальной отладки. На стенде всегда
поднимайте стек с `docker-compose.mtls.yml`.

### 3.2б. Redis и MinIO за mTLS

Со `docker-compose.mtls.yml` Redis, MinIO (и Ollama) доступны только по сертификату (`infra/pki/README.md`,
раздел «Хранилища за mTLS»). Перед первым запуском:

```bash
for s in redis minio ollama; do scripts/pki/enroll.sh "$s"; done
python3 scripts/gen_redis_acl.py              # пароли и ACL Redis (в .env и secrets/redis/)
python3 scripts/gen_minio_credentials.py      # случайные ключи MinIO вместо minioadmin
```

Без этих шагов `docker compose` не соберёт конфигурацию: пароли Redis обязательны. Ключи MinIO при
смене сохраняют данные бакета.

### 3.2а. Ключи подписи контекста пользователя

nginx пробрасывает сервисам не голые `X-User-Id` / `X-User-Role`, а подписанный auth-svc токен
`X-User-Context`; у каждого сервиса-получателя свой ключ проверки. Ключи создаёт скрипт
(`secrets/user-context/`, в `.gitignore`); без них auth-svc, chat-svc, library-svc и db-svc не
стартуют:

```bash
python3 scripts/gen_user_context_keys.py            # создать
python3 scripts/gen_user_context_keys.py --rotate   # добавить новый ключ, старые принимаются
```

Описание схемы и ротации — `services/auth-svc/app/user_context.py`, проверка —
`infra/nginx/tests/user_context_e2e.sh`.

### 3.3. Что обязательно сменить

| Что | Где | По умолчанию |
| :-- | :-- | :-- |
| Пароли БД: `POSTGRES_ADMIN_PASSWORD`, `AUTH_DB_PASSWORD`, `CHAT_DB_PASSWORD`, `LIBRARY_DB_PASSWORD`, `INGEST_DB_PASSWORD`, `GRAPH_DB_PASSWORD`, `DBSVC_DB_PASSWORD` | `.env` | предсказуемые значения из примера |
| `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` | `.env` | `minioadmin`-подобные |
| `DBSVC_ADMIN_TOKEN` | `.env` и `services/db-svc/.env` (должны совпадать) | `123456` |
| `SECRET_KEY` (подпись JWT) | `services/auth-svc/.env` | заглушка из примера |
| Пароль администратора `admin@edu.hse.ru` | после первого входа | `admin` |
| `FRONTEND_BASE_URL` | `services/auth-svc/.env` | `http://localhost` |
| `ADMIN_SESSION_COOKIE_SECURE=true` | `services/auth-svc/.env` | `false`; включать при HTTPS |

Пароль БД, меняемый после первого запуска, нужно менять и в самой базе: init-скрипты
исполняются только на пустом томе. Для этого есть `infra/db/init/roles/sync.sql` (команда в
`infra/db/README.md`): он приводит пароли и права к значениям из `.env`.

### 3.4. Профили и модели

- **LLM** — только через `llm-proxy` (`infra/llm-proxy/README.md`). Ключ роутера — `ROUTER_KEY`
  в `main/.env` (попадает только в окружение прокси). Режим (`router` / `ollama`), модель и адрес
  роутера — в `/etc/llm-proxy/config.json` на томе `llm_proxy_config`; при первом старте он
  создаётся из `infra/llm-proxy/config.default.json`, правки действуют со следующего запроса:

  ```bash
  docker compose exec llm-proxy cat /etc/llm-proxy/config.json
  docker compose exec -T llm-proxy sh -c 'cat > /etc/llm-proxy/config.json.tmp && mv /etc/llm-proxy/config.json.tmp /etc/llm-proxy/config.json' < my-config.json
  ```
- `COMPOSE_PROFILES=llm` поднимает резервную `ollama` и `ollama-init`, который скачивает модель
  `OLLAMA_MODEL` (по умолчанию `mistral`); она должна совпадать с `ollama.model` в `config.json`.
  По умолчанию профиль выключен.
- `EMBEDDER_MODEL_NAME` и `EMBEDDING_DIM` связаны: для `intfloat/multilingual-e5-base`
  размерность 768, она же объявлена в схеме БД. Смена модели = пересчёт всех векторов
  (см. «Миграция на e5» ниже).
- Настройки `graph-rag-svc` (таймауты, очередь, пределы входа) — `services/graph-rag-svc/.env`;
  адрес прокси (`LLM_BASE_URL`) задаёт compose.

## 4. Запуск

### Обновление подтверждения почты (IVHR-54 / IVHR-55)

Обновите `services/auth-svc` до версии с `app/verification.py` вместе с конфигурацией
nginx из этого репозитория. Нужны оба изменения: шлюз публикует
`POST /api/auth/resend-verification`, а mTLS-прокси auth-svc разрешает только сертификату
`db-svc` вызывать `POST /internal/notifications/email-verification` с JSON `{"user_id":"UUID"}`.
Шлюзу внутренний маршрут недоступен. Сам endpoint и вызов SMTP реализованы в auth-svc;
новая кнопка в админке этим изменением не добавляется.

В `services/auth-svc/.env` настройте `SMTP_*`, `EMAIL_FROM` и реальный публичный
`FRONTEND_BASE_URL` (http/https, без query и fragment), при необходимости
`EMAIL_VERIFY_RESEND_COOLDOWN_SECONDS=60`. Для шаблонов нужна уже существующая миграция
`009_email_templates.sql`; новых миграций нет. Перезапустите auth-svc и пересоберите
nginx; в режиме mTLS также перезапустите auth-svc-mtls для перечитывания конфигурации.
После обновления повторная регистрация больше не меняет пароль неподтверждённого аккаунта:
для нового письма следует использовать `/api/auth/resend-verification`.

Изолированная проверка реальных nginx/mTLS-конфигов без основного стека:

```bash
python3 infra/mtls/tests/email_verification_policy.py
```

Нужны Docker, openssl и образ `nginx:1.27-alpine`; проверка создаёт временные сертификаты,
сеть и два контейнера и удаляет их после завершения. Проверяет публичную повторную
отправку без access-токена, удаление поддельных пользовательских заголовков, допуск db-svc
и запрет остальных вызывающих. SMTP и приложение проверяются отдельно тестами auth-svc.

### Запуск стека

```bash
docker compose build
docker compose up -d
docker compose ps        # дождаться healthy у postgres, redis, minio, embedding-svc, ingest-worker
docker compose logs -f embedding-svc
```

Первый запуск долгий: `embedding-svc` скачивает веса (до 15 минут, `start_period` healthcheck'а
900 с), с профилем `llm` ещё и `ollama-init` тянет модель. `graph-rag-svc` и `ingest-worker`
стартуют только после того, как `embedding-svc` стал healthy; `graph-rag-svc` ещё ждёт
healthy `llm-proxy`.

Снаружи опубликован один порт — `nginx` (`NGINX_PORT`, по умолчанию 80). postgres, redis,
minio и все сервисы доступны только внутри сети compose; для `psql`:

```bash
docker compose exec postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

### Миграции существующей базы

На пустом томе `infra/db/init/init.sql` создаёт всё сам. Если база уже была поднята, примените
недостающие миграции по порядку из `infra/db/migrations/` (002–007):

```bash
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' \
  < infra/db/migrations/007_vector_column_dimension.sql
```

Миграции 006 (очередь индексации) и 007 (`core.vector_column_dimension`) нужны **до**
запуска новых версий `ingest-worker` и `graph-rag-svc`.

Миграция 008 (роли и журнал действий) переводит базу на отдельные роли сервисов: у `ingest-worker`
и `db-svc` появляются свои, а у остальных права сужаются до нужного. Перед ней добавьте в
корневой `.env` `INGEST_DB_*` и `DBSVC_DB_*` (образец — `.env.example`), пересоздайте postgres,
затем:

```bash
docker compose up -d postgres
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f -' \
  < infra/db/migrations/008_roles_and_audit.sql
docker compose up -d
```

Проверить результат: `infra/db/tests/check_roles.sh`. Подробности — `infra/db/README.md`.

Миграции 009–010 применяются так же; 011–012 — в составе перехода на e5 (следующий раздел).

### Миграция на e5 (пайплайн ноутбука)

Переход работающего стенда с `BAAI/bge-m3` (1024) на `intfloat/multilingual-e5-base` (768) и на
пайплайн ноутбука. Векторы разных моделей несравнимы, поэтому старые удаляются и всё
пересчитывается заново; пока переиндексация идёт, поиск находит меньше (но не чужие векторы).

**Чат недоступен всё время миграции:** `graph-rag-svc` остаётся остановленным до шага 9, где он
запускается снова, поэтому вопросы студентов эти часы не обрабатываются. Выберите окно заранее.

**Порядок важен.** Миграция 011 возвращает документы в `pending` и переводит колонку на
`VECTOR(768)`. Если в этот момент работает старый `ingest-worker` (`EMBEDDING_DIM=1024`, старый
`embedding-svc` на bge-m3), он заберёт документы, получит векторы 1024 и не сможет их вставить —
документы уйдут в `failed`. Поэтому воркер и `graph-rag-svc` останавливаются до миграции и
запускаются только после перехода `embedding-svc` на e5. Между шагами не запускайте стек целиком
(`docker compose up -d` без списка сервисов) и не поднимайте сервисы со старым `.env`.

1. Остановить потребителей эмбеддингов:

   ```bash
   docker compose stop ingest-worker graph-rag-svc
   ```
2. В `main/.env` (не в git) выставить:
   `EMBEDDING_DIM=768`, `EMBEDDER_MODEL_NAME=intfloat/multilingual-e5-base`, `ROUTER_KEY=<ключ
   роутера>`; убрать `GRAPH_RAG_WITH_LOCAL_LLM` и, если Ollama не нужна, `llm` из
   `COMPOSE_PROFILES`. С прежним `EMBEDDING_DIM=1024` `graph-rag-svc` и `ingest-worker` не
   стартуют.
3. В `services/graph-rag-svc/.env` убрать устаревшие `LLM_PROVIDER`, `OPENAI_*`, `OLLAMA_*`,
   `TRANSFORMERS_MODEL`, `DEVICE`, `JUDGE_MODE` и поставить `EMBEDDING_DIM=768` (образец —
   `.env.example` сервиса). Compose всё равно передаёт `EMBEDDING_DIM` и `LLM_BASE_URL` поверх
   этого файла, но лишние переменные вводят в заблуждение.
4. Применить миграции (011 очищает `library.chunk_embeddings`, переводит колонку на `VECTOR(768)`,
   создаёт таблицы быстрых ответов и ссылок и возвращает проиндексированные документы в
   `pending`; 012 — права `ingest_user` на новые таблицы):

   ```bash
   for m in 011_notebook_pipeline 012_notebook_grants; do
     docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -f -' \
       < infra/db/migrations/$m.sql
   done
   ```
5. Перевести `embedding-svc` на e5 и поднять `llm-proxy`, затем убедиться, что модель новая:

   ```bash
   docker compose up -d --build embedding-svc llm-proxy
   docker compose exec embedding-svc python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/ping').read().decode())"
   # ждать "model": "intfloat/multilingual-e5-base", "dimension": 768 (до загрузки весов — 503)
   ```
6. Запустить `ingest-worker` и дождаться переиндексации всех документов:

   ```bash
   docker compose up -d --build ingest-worker
   ```

   ```sql
   SELECT ingest_status, count(*) FROM library.documents GROUP BY 1;  -- ждать, пока не останется pending/processing
   SELECT embedding_model, count(*) FROM library.chunk_embeddings GROUP BY 1;
   ```

   Затем **отдельно проверить, что `failed` — ноль**: в первом запросе не должно быть строки
   `failed`. Если есть, посмотреть причину и вернуть такие документы в очередь:

   ```sql
   SELECT id, title, ingest_error FROM library.documents WHERE ingest_status = 'failed';
   UPDATE library.documents
      SET ingest_status = 'pending', ingest_attempts = 0, ingest_next_attempt_at = NULL, ingest_error = NULL
    WHERE ingest_status = 'failed';
   ```

   Триггер разбудит воркер; повторить проверку. SQL выполняется через `psql` из раздела 4.
7. **Длина чанков (не проверено на корпусе).** `multilingual-e5-base` принимает не больше 512
   токенов, а чанкер ноутбука режет до 1600 символов (плюс заголовок «Название документа /
   Категория / Раздел»). На русском это около 3–4 символов на токен, то есть длинный чанк может
   подойти к пределу или превысить его; всё сверх 512 токенов модель молча отбрасывает, и хвост
   чанка в векторе не учитывается (BM25 его видит). Доля таких чанков:

   ```bash
   SQL="COPY (SELECT 'Название документа: ' || d.title || chr(10) || 'Категория: ' || d.category || chr(10) || 'Раздел: ' || coalesce(c.section_path, '') || chr(10) || 'Текст: ' || c.text FROM library.chunks c JOIN library.documents d ON d.id = c.document_id) TO STDOUT WITH (FORMAT csv)"
   echo "$SQL" | docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q -f -' \
     | docker compose exec -T embedding-svc python -c 'import sys, textwrap; exec(textwrap.dedent(sys.argv[1]))' '
   import csv, sys
   from transformers import AutoTokenizer
   tok = AutoTokenizer.from_pretrained("intfloat/multilingual-e5-base")
   lens = [len(tok("passage: " + row[0])["input_ids"]) for row in csv.reader(sys.stdin)]
   over = sum(n > 512 for n in lens)
   print(f"чанков: {len(lens)}, длиннее 512 токенов: {over} ({over / max(len(lens), 1):.1%}), максимум: {max(lens, default=0)}")
   '
   ```

   (Код Python обёрнут в `textwrap.dedent`, поэтому команду можно вставлять прямо из файла вместе
   с отступом списка.)

   Если доля заметная, решение за владельцем: уменьшить `max_chars` в
   `services/ingest-worker/app/notebook_chunker.py` (1600 / 1400; это расхождение с ноутбуком) и
   переиндексировать документы.
8. Настроить `config.json` прокси (раздел 3.4): модель и адрес роутера.
9. Запустить `graph-rag-svc` и `db-svc` с новыми переменными:

   ```bash
   docker compose up -d --build graph-rag-svc db-svc
   ```

   `graph-rag-svc` при старте сверяет размерность (768) и строит индекс по уже
   переиндексированным чанкам.
10. Загрузить быстрые ответы и ссылки через админку (`/admin/`, или напрямую с токеном):
    `POST /api/db/library/quick-answers/import` (файл `HSE_Answers_RU.xlsx`) и
    `POST /api/db/library/links/import` (`all_links.txt`), поле `file`. Векторы досчитает
    `ingest-worker` (`SELECT count(*) FROM library.quick_answer_variants WHERE embedding IS NULL`).
11. Проверить вопрос через чат или `POST /generate` в режиме `sync`. Новые чанки
    `graph-rag-svc` подхватывает сам, раз в 60 с.
12. После миграции запустить `infra/db/tests/check_roles.sh` (имя контейнера — по умолчанию
    `postgres`): ожидается, что все проверки пройдены («0 провалено»).

`graph.entities.name_embedding` остаётся `VECTOR(1024)`: GraphRAG отключён и граф не читается.

### Внутренний центр сертификации (необязательно)

Профиль compose `pki` поднимает `step-ca`: он выдаёт сервисам короткоживущие сертификаты для
взаимной TLS-аутентификации. Обычный запуск стека его не включает.

```bash
scripts/pki/init.sh                              # один раз; увезите pki/root/ с машины
docker compose --profile pki up -d step-ca
scripts/pki/enroll.sh <имя-сервиса>
```

Срок жизни сертификатов — `PKI_CERT_TTL` в `.env` (по умолчанию `24h`). Подробности и проверка —
`infra/pki/README.md`.

Пошаговый запуск PKI, выпуск сертификатов (первый выпуск делается вручную, автоматически только
обновление) и разбор типичных поломок (502 из-за истёкшего сертификата и др.) — в
`infra/pki/README.md`, раздел «Методичка: запуск PKI и выпуск сертификатов».

Поверх него `docker-compose.mtls.yml` закрывает все HTTP-связи стека взаимной TLS-аутентификацией:
шлюз (nginx) и сервисы ходят друг к другу только с сертификатами нашего CA, а что вызывающему можно,
решает его CN (`infra/mtls/*.conf`; шлюзу, например, запрещён `/internal/*`). Порядок включения,
ограничения и проверки — в `infra/pki/README.md`, раздел «mTLS между шлюзом и сервисами и между
сервисами».

### Метрики, логи и дашборды (необязательно)

Отдельный оверлей поднимает Prometheus, Loki, Grafana и экспортёры (`docker-compose.observability.yml`,
профиль `observability`). В `.env` нужны `GRAFANA_ADMIN_PASSWORD` и `MONITORING_DB_PASSWORD`;
Grafana слушает только `127.0.0.1:3000`, пользователь `admin`. Роль мониторинга в Postgres создаётся
при инициализации базы либо через `roles/sync.sql`. За mTLS Prometheus нужен собственный сертификат:
`scripts/pki/enroll.sh prometheus --uid 65534 --gid 65534`; redis_exporter - `enroll.sh redis-exporter --uid 59000 --gid 59000`.
Вход postgres_exporter по сертификату вместо пароля - оверлей `docker-compose.observability.dbcert.yml`. Подробности и список метрик -
`infra/observability/README.md`.

## 5. Первичное наполнение

1. Откройте `http://<хост>:<NGINX_PORT>`, войдите администратором `admin@edu.hse.ru` / `admin`
   и сразу смените пароль.
2. Загрузите документы через админ-панель (`/admin/`) или подключите краулер.
   `ingest-worker` подхватывает новые документы сам (LISTEN/NOTIFY), режет на чанки и считает
   эмбеддинги.
3. Загрузите быстрые ответы (Excel) и полезные ссылки (`all_links.txt`) — шаг 10 раздела
   «Миграция на e5». Граф строить не нужно: GraphRAG отключён.
4. Проверьте сквозной сценарий скриптами из `tests/` (`test_flow.py`, `test_library.py`).
   `tests/test_notebook_pipeline_flow.py` проверяет путь вопроса без стека, на одноразовых
   контейнерах (нужен только docker).

## 6. Почта сервиса для писем и уведомлений

Письма отправляет `auth-svc` по SMTP: подтверждение e-mail при регистрации и сброс пароля.
Email-уведомления из бэклога (IVHR-53–56: шаблоны, внутренние роуты) будут использовать тот же
ящик. Нужен **отдельный служебный ящик**, а не личный: на него не должны попадать ответы
пользователей, и его пароль не должен быть чьим-то рабочим.

### 6.1. Создать ящик

Подойдёт любой SMTP-провайдер; ниже самые простые варианты (ограничения провайдеров
меняются, сверяйтесь с их документацией).

- **Gmail / Google Workspace.** Создайте аккаунт вида `pochemuchnik.noreply@gmail.com`,
  включите двухэтапную аутентификацию и выпустите «Пароль приложения»
  (Аккаунт Google → Безопасность → Пароли приложений). Обычный пароль для SMTP не подойдёт.
  Лимит отправки у бесплатного аккаунта — порядка сотен писем в сутки.
- **Яндекс 360 / Mail.ru / корпоративная почта.** Создайте ящик, включите доступ по SMTP/IMAP в
  настройках и выпустите пароль приложения. Для почты университета ящик и параметры SMTP
  запрашиваются у ИТ-службы.
- **Свой домен.** Заведите `noreply@<домен>` и настройте DNS: SPF, DKIM и DMARC. Без них
  письма уйдут в спам.
- **Разработка.** Локальный SMTP без авторизации, например Mailpit: `SMTP_USER` и
  `SMTP_PASSWORD` оставьте пустыми.

### 6.2. Прописать в `services/auth-svc/.env`

```env
SMTP_HOST=smtp.gmail.com        # smtp.yandex.ru, smtp.mail.ru и т. д.
SMTP_PORT=587
SMTP_USER=pochemuchnik.noreply@gmail.com
SMTP_PASSWORD=<пароль приложения>
SMTP_USE_TLS=true               # STARTTLS на порту 587
SMTP_USE_SSL=false              # для SMTPS на порту 465: SSL=true, TLS=false
EMAIL_FROM=pochemuchnik.noreply@gmail.com
FRONTEND_BASE_URL=https://<публичный адрес сайта>
```

- Одновременно `SMTP_USE_TLS` и `SMTP_USE_SSL` включать нельзя.
- `SMTP_USER` и `SMTP_PASSWORD` задаются только вместе.
- `EMAIL_FROM` обязателен; у Gmail адрес отправителя всё равно подменяется на аутентифицированный,
  поэтому он должен совпадать с `SMTP_USER`.
- `FRONTEND_BASE_URL` должен быть публичным: ссылки в письмах строятся от него
  (`<FRONTEND_BASE_URL>/<путь>?token=...`). С `http://localhost` пользователь получит ссылку,
  которая у него не откроется.
- Пароль лежит только в `services/auth-svc/.env` (в git не попадает). После правки:
  `docker compose up -d --force-recreate auth-svc`.

### 6.3. Проверить

Зарегистрируйте тестового пользователя на реальный адрес и дождитесь письма. Если письмо не
пришло, смотрите `docker compose logs auth-svc`: ошибки отправки приходят как
`EmailDeliveryError` с указанием, какой параметр не задан или отвергнут сервером.

## 7. Эксплуатация

```bash
docker compose logs -f <сервис>               # логи
docker compose up -d --build <сервис>         # пересобрать один сервис
docker compose up -d --force-recreate         # применить новые .env
git pull && git submodule update --init --recursive   # обновить код вместе с сабмодулями
docker compose down                            # остановить (тома сохраняются)
```

## 8. Перед публикацией в интернет

- Все пункты из 3.3 выполнены, токены сгенерированы скриптом.
- Перед nginx стоит HTTPS (сертификат на reverse proxy или в самом nginx),
  `ADMIN_SESSION_COOKIE_SECURE=true`.
- Наружу опубликован только nginx (`docker compose config` не показывает других `ports`).
- `library-svc`, `chat-svc` и `db-svc` не проверяют JWT клиента сами: они принимают подписанный
  `X-User-Context`, который выписывает auth-svc и пробрасывает nginx. Голые `X-User-Id` и
  `X-User-Role` не принимаются (`USER_CONTEXT_ALLOW_LEGACY` в рабочей среде не включать).
