# Развёртывание «Почемучника»

Что нужно, чтобы поднять проект с нуля. Подробности по каждому сервису — в его README
(`services/<имя>/README.md`), карта сервисов — `services/README.md`.

> Стек целиком ещё не прогонялся end-to-end: контейнеры поднимаются, вход в админку проверен,
> но путь «вопрос → ответ» и сборка графа на реальных данных не проверялись.

## 1. Что нужно на машине

| Что | Зачем |
| :-- | :-- |
| Docker Engine + Compose v2 (**системный движок, не Docker Desktop**) | Docker Desktop на Linux держит свою VM, в которую GPU не пробрасывается (`failed to discover GPU vendor from CDI`) |
| NVIDIA GPU + драйвер + `nvidia-container-toolkit` | `embedding-svc` резервирует GPU (модель `BAAI/bge-m3`), `ollama` тоже |
| Git ≥ 2.13 | В проекте сабмодули |
| ~15 ГБ свободного диска | Образы, веса `bge-m3` (~2.3 ГБ), модель ollama, тома postgres/minio |
| Доступ в интернет при первом запуске | Скачивание весов с Hugging Face и модели ollama |
| Почтовый ящик сервиса | Письма подтверждения и сброса пароля, см. раздел 6 |

pnpm и Node на хосте не нужны: фронтенд собирается внутри образа `nginx` (`infra/nginx/Dockerfile`).

Без GPU стек не запустится в таком виде: уберите `llm` из `COMPOSE_PROFILES` в `.env`, а для
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

### 3.2. Межсервисные токены

В `.env.example` везде стоит `CHANGE_ME`. Сгенерируйте случайные токены (скрипт сам
согласует `SERVICE_TOKEN` вызывающих и `TRUSTED_SERVICE_TOKENS` принимающих):

```bash
python3 scripts/gen_service_tokens.py            # заполнить слабые и пустые
python3 scripts/gen_service_tokens.py --rotate   # перевыпустить все
```

Со слабым токеном (заглушка или короче 24 символов) `auth-svc`, `chat-svc`, `graph-rag-svc`
и `embedding-svc` не стартуют. После ротации нужно пересоздать контейнеры.

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

- `COMPOSE_PROFILES=llm` поднимает `ollama` и `ollama-init`, который скачивает модель
  `OLLAMA_MODEL` (по умолчанию `mistral`).
- `EMBEDDER_MODEL_NAME` и `EMBEDDING_DIM` связаны: для `BAAI/bge-m3` размерность 1024, она же
  объявлена в схеме БД. Смена модели = пересчёт всех чанков и графа
  (`services/graph-rag-svc/README.md`, §13.1).
- Настройки LLM и графа — `services/graph-rag-svc/.env`.

## 4. Запуск

```bash
docker compose build
docker compose up -d
docker compose ps        # дождаться healthy у postgres, redis, minio, embedding-svc, ingest-worker
docker compose logs -f embedding-svc
```

Первый запуск долгий: `embedding-svc` скачивает веса (до 15 минут, `start_period` healthcheck'а
900 с), `ollama-init` тянет модель. `graph-rag-svc` и `ingest-worker` стартуют только после
того, как `embedding-svc` стал healthy.

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

## 5. Первичное наполнение

1. Откройте `http://<хост>:<NGINX_PORT>`, войдите администратором `admin@edu.hse.ru` / `admin`
   и сразу смените пароль.
2. Загрузите документы через админ-панель (`/admin/`) или подключите краулер.
   `ingest-worker` подхватывает новые документы сам (LISTEN/NOTIFY), режет на чанки и считает
   эмбеддинги.
3. Постройте граф (оффлайн-команда, один раз и после крупных изменений данных):

   ```bash
   docker compose run --rm graph-rag-svc python -m cli.build_graph --full-rebuild
   ```

4. Проверьте сквозной сценарий скриптами из `tests/` (`test_flow.py`, `test_library.py`).

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
