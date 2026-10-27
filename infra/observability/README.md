# Наблюдаемость: метрики, логи, дашборды

Prometheus собирает метрики сервисов, хранилищ и машины, Loki хранит логи всех контейнеров
(их читает Grafana Alloy), Grafana показывает всё на семи дашбордах. Включается отдельным
оверлеем `docker-compose.observability.yml` и профилем `observability`; без них стек работает как
раньше. Дизайн и решения: `docs/superpowers/specs/2026-10-27-observability-design.md`.

```
сервисы /metrics ─┐
экспортёры ───────┼─► Prometheus ─┐
node-exporter,    │  (15 дней)    ├─► Grafana (127.0.0.1:3000)
cAdvisor ─────────┘               │
логи контейнеров ─► Alloy ─► Loki ┘  (14 дней)
```

## Что поднимается

| Контейнер | Зачем |
| :-- | :-- |
| `prometheus` | сбор и хранение метрик (`--storage.tsdb.retention.time=15d`) |
| `loki`, `alloy` | хранение логов (`retention_period: 336h`) и их доставка из Docker (метка `service` = имя compose-сервиса) |
| `grafana` | дашборды из файлов; наружу только `127.0.0.1:${GRAFANA_PORT:-3000}`, вход `admin` / `GRAFANA_ADMIN_PASSWORD` |
| `node-exporter`, `cadvisor` | состояние машины и контейнеров |
| `redis-exporter`, `postgres-exporter`, `nginx-exporter` | метрики хранилищ и шлюза; у MinIO свои (`/minio/v2/metrics/cluster`) |

## Подключение

В корневом `.env` задайте `GRAFANA_ADMIN_PASSWORD` и `MONITORING_DB_PASSWORD` (см. `.env.example`),
затем:

```bash
docker compose -f docker-compose.yml -f docker-compose.observability.yml --profile observability up -d
# или постоянно: COMPOSE_FILE=docker-compose.yml:docker-compose.observability.yml и COMPOSE_PROFILES=...,observability
```

**Роль для postgres_exporter.** Скрипты инициализации выполняются только на пустом томе. На уже
работающей базе создайте роль так же, как обновляют остальные (она появится, если задан
`MONITORING_DB_PASSWORD` в окружении контейнера postgres, то есть после пересоздания контейнера
с новым оверлеем):

```bash
docker compose -f docker-compose.yml -f docker-compose.observability.yml up -d postgres
docker compose exec -T postgres psql -U "$POSTGRES_ADMIN_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
    -f /docker-entrypoint-initdb.d/roles/sync.sql
```

Роль `monitoring_user` входит в `pg_monitor`, данных приложения не видит, лимит 3 соединения.

## За mTLS

Приложения за mTLS слушают только `127.0.0.1` внутри сети своего прокси-сайдкара, поэтому
Prometheus ходит на `:8443` каждого сервиса с собственным сертификатом (CN `prometheus`), а прокси
пускают его только на `GET /metrics` (`infra/mtls/<сервис>.conf`). Шлюзу и другим сервисам
`/metrics` закрыт (403).

```bash
scripts/pki/enroll.sh prometheus --uid 65534 --gid 65534       # владелец файлов: пользователь образа prometheus
scripts/pki/enroll.sh redis-exporter --uid 59000 --gid 59000
python3 scripts/gen_redis_acl.py                               # добавит пользователя prometheus и REDIS_PROMETHEUS_PASSWORD
# COMPOSE_FILE=docker-compose.yml:docker-compose.pki.yml:docker-compose.mtls.yml:docker-compose.observability.yml:docker-compose.observability.mtls.yml
```

`docker-compose.observability.mtls.yml` подменяет конфигурацию Prometheus на
`prometheus.mtls.yml`, выпускает обновление сертификатов и настраивает redis_exporter на `rediss://`.

Ограничения, о которых стоит знать:

- **ingest-worker** не принимает входящих соединений (нет прокси), поэтому его метрики отдаёт
  отдельный порт `METRICS_PORT` (9464) по http внутри `app-network`. Отдаёт только метрики.
- **postgres_exporter** за `docker-compose.pki.yml` по умолчанию входит ролью по паролю через TLS
  (`sslmode=require`, группа `pw_login`). Вход по клиентскому сертификату включает третий оверлей
  `docker-compose.observability.dbcert.yml` (`MONITORING_DB_AUTH=cert`, сертификат
  `scripts/pki/enroll.sh monitoring_user --uid 65534 --gid 65534`); пароль тогда не нужен.
  Без этого оверлея `MONITORING_DB_PASSWORD` обязателен: пустой пароль в режиме password роль не создаёт.
- **nginx**: `stub_status` слушает порт 8081 шлюза, наружу он не публикуется; достижим из
  `app-network`. Отдаёт только счётчики соединений.
- **Alloy** читает `docker.sock` (только чтение): кто контролирует этот контейнер, видит все
  контейнеры хоста. Это обычная цена сбора логов из Docker.

## Метрики сервисов

HTTP-метрики (`http_requests_total`, `http_request_duration_seconds`, `http_requests_inprogress`)
есть у auth, chat, library, db, graph-rag и embedding; метка `handler` - шаблон маршрута, а не
реальный путь. Бизнес-метрики (префикс `pochemuchnik_`; метки с неограниченным числом значений,
идентификаторы пользователей и тексты вопросов запрещены):

| Сервис | Метрики |
| :-- | :-- |
| auth-svc | `registrations_total`, `logins_total{result}`, `token_refresh_total{result}`, `emails_sent_total{kind,result}`, `admin_sessions_total` |
| chat-svc | `ws_connections_active`, `ws_connections_total`, `messages_total{role}`, `time_to_first_token_seconds`, `answer_duration_seconds{outcome}`, `generation_failures_total{reason}`, `feedback_total{value}`, `redis_cache_requests_total{kind,outcome}` |
| graph-rag-svc | `generate_requests_total{mode}`, `judge_decisions_total{route}`, `stage_duration_seconds{stage}`, `context_chunks`, `empty_context_total`, `llm_errors_total`, `retrieval_failures_total` |
| embedding-svc | `embed_requests_total`, `embed_batch_size`, `embed_duration_seconds` |
| library-svc | `preview_requests_total{mode}`, `preview_cache_requests_total{outcome}`, `preview_cache_evictions_total`, `preview_convert_duration_seconds`, `downloads_total`, `documents{status}` |
| ingest-worker | `ingest_queue_depth{status}`, `ingest_jobs_total{result}`, `ingest_job_duration_seconds{result}`, `ingest_chunks_created_total`, `ingest_job_errors_total{type}` |
| db-svc | `admin_actions_total{action,result}`, `imports_total{kind,result}`, `corpus_objects{kind}` |

Отличия от первоначального плана в дизайн-документе: добавлен `retrieval_failures_total`; размер
корпуса и графа - один gauge `corpus_objects{kind}`; у `answer_duration_seconds` есть метка `outcome`;
причины `generation_failures_total` - `llm_error` (graph-rag-svc прислал `message_error`) и
`internal_error` (сбой обработки события в chat-svc), потому что текст ошибки метрикой быть не может.

## Дашборды

Семь дашбордов лежат в `grafana/dashboards/` и подхватываются Grafana из файлов: «Обзор стека»,
«Хост и контейнеры», «Чат и RAG», «Документы и ingest», «Пользователи и админка», «Хранилища»,
«Логи». JSON генерирует `grafana/generate_dashboards.py`: правьте скрипт и запускайте его заново.
`grafana/exporter_metrics.txt` - каталог имён метрик экспортёров, по которому `dashboards_check.py`
проверяет запросы.

## Проверки

Все проверки идут на одноразовых контейнерах и не трогают работающий стек; `llm` и `embedding-svc`
не запускаются.

| Скрипт | Что проверяет |
| :-- | :-- |
| `tests/stack_e2e.sh` | Prometheus, Loki, Alloy, Grafana, node-exporter, cAdvisor; загрузку дашбордов; валидность всех запросов PromQL и LogQL (`queries_check.py`) |
| `tests/exporters_e2e.sh` | экспортёры Redis, Postgres, nginx и метрики MinIO на настоящих хранилищах; права роли мониторинга; `nginx -t` для шлюза |
| `tests/postgres_cert_e2e.sh` | вход postgres_exporter по клиентскому сертификату (роль без пароля, чужой сертификат отвергается) |
| `tests/metrics_policy.sh` | политику `/metrics` в прокси всех сервисов (настоящие конфиги) и сбор настоящим Prometheus с `prometheus.mtls.yml` |
| `tests/dashboards_check.py` | JSON дашбордов, существование метрик в запросах, использование каждой бизнес-метрики |
| `tests/service_metrics_tests.sh` | HTTP-метрики всех сервисов (и бизнес-метрики embedding-svc) в лёгком контейнере |
| `tests/service_unit_tests.sh <сервис> [тесты]` | тесты сервиса с его зависимостями (бизнес-метрики) |

Через mTLS экспортёры проверяют `infra/mtls/tests/redis_e2e.sh` (redis_exporter с ACL-пользователем
`prometheus`, чужой сертификат и неверный пароль дают `redis_up 0`) и `minio_e2e.sh` (Prometheus читает только
`/minio/v2/metrics/{cluster,node}`).

Существующие проверки `infra/mtls/tests/*_e2e.sh` запускают код сервисов в уже собранных образах:
после изменений в сервисах сначала пересоберите образы (`docker compose build`), иначе им не
хватит `prometheus_client`.
