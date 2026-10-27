# Наблюдаемость: план реализации

> **Для исполнителя:** REQUIRED SUB-SKILL: superpowers:executing-plans (выполняется в этой сессии). Шаги отмечаются чекбоксами.

**Цель:** Prometheus, Loki, Alloy, Grafana, node-exporter и cAdvisor рядом со стеком; HTTP- и бизнес-метрики в сервисах; сбор за mTLS с сертификатом Prometheus; семь дашбордов из файлов.

**Архитектура:** отдельный оверлей `docker-compose.observability.yml` (профиль `observability`). Prometheus собирает `/metrics` напрямую (простой режим) или через сайдкары на `:8443` с сертификатом `prometheus` (mTLS). Логи читает Alloy из Docker и пишет в Loki. Datasource и дашборды провижинятся из `infra/observability/`.

**Стек:** Prometheus, Loki (один бинарник), Grafana Alloy, Grafana, node-exporter, cAdvisor, redis_exporter, postgres_exporter, nginx-prometheus-exporter; Python `prometheus-client` и `prometheus-fastapi-instrumentator`.

**Спецификация:** `docs/superpowers/specs/2026-10-27-observability-design.md`

## Глобальные ограничения

- Работа в ветке `dev`. Изменения сервисов коммитятся в их сабмодулях, затем отдельный коммит в `main` с обновлением ссылки. `crawler-svc` и `frontend` не трогать.
- Коммиты по задачам: `IVHR-84 <название из Jira>` для контейнеров/инфраструктуры, `IVHR-85 <название из Jira>` для сбора метрик и логов; одна строка, без `Co-Authored-By`; в индекс только свои правки.
- Не пушить; статусы Jira не менять без просьбы.
- Не запускать профиль `llm` и `embedding-svc`; сервисы проверять на одноразовых контейнерах.
- Префикс бизнес-метрик `pochemuchnik_`. Метки с неограниченным числом значений (id пользователя, id документа, путь с id) и тексты вопросов/ответов в метриках запрещены.
- Сроки хранения: метрики 15 дней, логи 14 дней. Алерты не делаем.
- Grafana публикуется только на `127.0.0.1:3000`, пароль из `.env`.
- Сборка логов: Grafana Alloy, `docker.sock` только на чтение.

## Review Focus

- Публичный шлюз (nginx) не должен отдавать `/metrics` наружу: проверить, что запрос `GET /metrics` через nginx не возвращает метрик (Задача 3).
- Недоступный сервис не должен ломать сбор: цель в статусе down, остальные собираются (Задача 1).
- Ошибка внутри сбора метрик или лишняя метка не должны ронять запрос пользователя (Задачи 3 и 4).
- Сервис с несколькими воркерами uvicorn: счётчики не должны расходиться между воркерами (проверить, сколько воркеров запускает каждый сервис, Задача 3).
- Вызывающий не `prometheus` на `/metrics` получает 403, а `prometheus` на любой другой путь тоже 403 (Задача 2).

---

### Задача 1: Оверлей наблюдаемости в простом режиме

**Файлы:**
- Создать: `docker-compose.observability.yml`, `infra/observability/prometheus/prometheus.yml`, `infra/observability/loki/loki.yml`, `infra/observability/alloy/config.alloy`, `infra/observability/grafana/provisioning/datasources/datasources.yml`, `infra/observability/grafana/provisioning/dashboards/dashboards.yml`, `infra/observability/tests/stack_e2e.sh`
- Изменить: `.env.example` (`GRAFANA_ADMIN_PASSWORD`, `GRAFANA_PORT=3000`)

**Интерфейсы:**
- Производит: сеть `app-network` подключена к prometheus; сервисы `prometheus`, `loki`, `alloy`, `grafana`, `node-exporter`, `cadvisor`; переменная `PROMETHEUS_CONFIG` (по умолчанию `prometheus.yml`); каталог дашбордов `infra/observability/grafana/dashboards/*.json`, который Grafana читает при старте.
- Метка `service` в Loki берётся из `com.docker.compose.service`.

- [ ] **Шаг 1: Написать `stack_e2e.sh`.** Поднимает только сервисы наблюдаемости; проверяет: `promtool check config`, `GET prometheus:9090/api/v1/targets` содержит `node-exporter` и `cadvisor` в состоянии up, `loki:3100/ready` отвечает `ready`, Grafana `/api/datasources` содержит Prometheus и Loki, в Loki по запросу `{service=~".+"}` есть строки логов.
- [ ] **Шаг 2: Запустить, убедиться, что падает** (нет оверлея).
- [ ] **Шаг 3: Написать оверлей и конфиги.** Профиль `observability`; тома для данных Prometheus, Loki, Grafana; `--storage.tsdb.retention.time=15d`; Loki с `retention_period: 336h` и compactor; в `prometheus.yml` цели node-exporter, cadvisor и сервисов по http (пока часть недоступна: цель down допустима).
- [ ] **Шаг 4: Запустить `stack_e2e.sh`, убедиться, что проходит.**
- [ ] **Шаг 5: Коммит** `IVHR-84 Сделать список infrastructure контейнеров и подключить их к проекту, вроде мониторинга, сборки логов и тд`.

### Задача 2: Сбор за mTLS и сертификат Prometheus

**Файлы:**
- Изменить: `infra/mtls/<auth-svc|chat-svc|library-svc|db-svc|graph-rag-svc|embedding-svc>.conf` (правило `"~^prometheus:/metrics$" 1`), `docker-compose.observability.yml` (том с сертификатом, обновлятель `prometheus-certs` в профиле `pki`)
- Создать: `infra/observability/prometheus/prometheus.mtls.yml`, `infra/observability/tests/metrics_policy.sh`
- Изменить: `infra/pki/README.md` (выдача сертификата `prometheus`)

**Интерфейсы:**
- Потребляет: `scripts/pki/enroll.sh <имя>`, шаблон обновлятеля из `infra/pki/README.md`, образец политики в `infra/mtls/tests/policy_client.py`.
- Производит: сертификат CN=`prometheus` в томе `mtls_prometheus`, монтируется в `/pki-svc`; `prometheus.mtls.yml` ходит на `https://<сервис>:8443/metrics` с этим сертификатом.

- [ ] **Шаг 1: Тест политики** в `metrics_policy.sh` (по образцу `infra/mtls/tests/*.sh`): `prometheus` + `GET /metrics` → 200; `prometheus` + любой другой путь → 403; другой CN + `/metrics` → 403.
- [ ] **Шаг 2: Убедиться, что падает.**
- [ ] **Шаг 3: Добавить правило в `.conf` каждого сервиса, `prometheus.mtls.yml`, обновлятель сертификата.**
- [ ] **Шаг 4: Тест проходит** на одноразовых контейнерах.
- [ ] **Шаг 5: Коммит** `IVHR-84 …` (сертификат и политика).

### Задача 3: HTTP-метрики во всех HTTP-сервисах

**Файлы (по сервису: auth-svc, chat-svc, library-svc, db-svc, graph-rag-svc, embedding-svc):**
- Создать: `app/metrics.py`, тест `tests/test_metrics.py` (или рядом с существующими тестами сервиса)
- Изменить: `app/main.py` (вызов `setup_metrics(app)`), `requirements.txt` (`prometheus-client`, `prometheus-fastapi-instrumentator`), внутренняя проверка вызывающего (пропустить `/metrics`, если вызывающий `prometheus`)
- Изменить: `infra/nginx/nginx.conf` (убедиться, что `/metrics` не проксируется наружу)

**Интерфейсы:**
- Производит: `def setup_metrics(app: FastAPI) -> None` в `app/metrics.py` каждого сервиса: добавляет `/metrics`, метрики запросов по шаблону маршрута и коду. Метрики не должны ломать запрос при ошибке.

- [ ] **Шаг 1: Тест** `test_metrics_endpoint_exposes_http_metrics`: после запроса к любому маршруту `GET /metrics` содержит `http_request_duration_seconds` с шаблоном маршрута, а не с реальным путём.
- [ ] **Шаг 2: Убедиться, что падает.**
- [ ] **Шаг 3: Реализовать `setup_metrics`** на `prometheus-fastapi-instrumentator`; проверить число воркеров uvicorn в `Dockerfile`/`command`; при нескольких воркерах включить multiprocess-режим.
- [ ] **Шаг 4: Тест проходит; через nginx `GET /metrics` метрик не отдаёт.**
- [ ] **Шаг 5: Коммит в каждом сабмодуле** `IVHR-85 централизованный сбор логов и метрик`, затем один коммит в `main`.

### Задача 4: Бизнес-метрики по сервисам

**Файлы:** `app/metrics.py` каждого сервиса (счётчики и гистограммы), точки вызова в бизнес-коде, тест на каждую группу метрик.

**Интерфейсы:** имена метрик (все с префиксом `pochemuchnik_`), по сервисам:
- auth-svc: `registrations_total`, `logins_total{result}`, `token_refresh_total{result}`, `emails_sent_total{kind,result}`, `admin_sessions_total`
- chat-svc: `ws_connections_active` (gauge), `ws_connections_total`, `messages_total{role}`, `time_to_first_token_seconds`, `answer_duration_seconds`, `generation_failures_total{reason}`, `feedback_total{value}`, `redis_cache_requests_total{kind,outcome}`
- graph-rag-svc: `generate_requests_total{mode}`, `judge_decisions_total{route}`, `stage_duration_seconds{stage}`, `context_chunks` (histogram), `empty_context_total`, `llm_errors_total`
- embedding-svc: `embed_requests_total`, `embed_batch_size`, `embed_duration_seconds`
- library-svc: `preview_requests_total{mode}`, `preview_cache_requests_total{outcome}`, `preview_cache_evictions_total`, `preview_convert_duration_seconds`, `downloads_total`, `documents{status}` (gauge, обновляется при сборе)
- ingest-worker: `queue_depth`, `jobs_total{result}`, `job_duration_seconds`, `chunks_created_total`, `job_errors_total{type}`; у воркера нет HTTP, поэтому небольшой http-сервер метрик на порту из `METRICS_PORT`
- db-svc: `admin_actions_total{action}`, `imports_total{kind,result}`, `corpus_documents`, `corpus_chunks`, `graph_nodes`, `graph_edges` (gauge)

- [ ] **Шаг 1–4 для каждого сервиса:** тест, что действие увеличивает нужный счётчик (например, `test_login_failure_increments_logins_total_with_result_failed`); падение; реализация; проход.
- [ ] **Шаг 5: Коммит в каждом сабмодуле** `IVHR-85 …`, затем коммит в `main`.

### Задача 5: Экспортеры хранилищ

**Файлы:**
- Изменить: `docker-compose.observability.yml` (redis-exporter, postgres-exporter, nginx-exporter), `scripts/gen_redis_acl.py` (пользователь `prometheus`, права на чтение статистики), `infra/db/init/…` (роль `monitoring` с `pg_monitor`, вход по сертификату), `infra/nginx/nginx.conf` (внутренний `stub_status`), `prometheus.yml` и `prometheus.mtls.yml` (цели, включая MinIO `/minio/v2/metrics/cluster`)
- Тест: `infra/observability/tests/exporters_e2e.sh`

- [ ] **Шаг 1: Тест**: цели `redis`, `postgres`, `minio`, `nginx` в состоянии up, метрики `redis_up`, `pg_up`, `minio_cluster_health_status`, `nginx_up` равны 1.
- [ ] **Шаг 2: Убедиться, что падает.** **Шаг 3: Реализовать.** **Шаг 4: Тест проходит.**
- [ ] **Шаг 5: Коммит** `IVHR-84 …`.

### Задача 6: Дашборды Grafana

**Файлы:** `infra/observability/grafana/dashboards/{overview,host,chat-rag,documents-ingest,auth,storage,logs}.json`; `infra/observability/tests/dashboards_check.py`

- [ ] **Шаг 1: Тест `dashboards_check.py`:** все семь JSON валидны, `uid` уникальны, каждая метрика `pochemuchnik_*` из Задачи 4 используется хотя бы на одном дашборде, каждое выражение PromQL ссылается на метрику, объявленную в сервисах или в списке экспортеров.
- [ ] **Шаг 2: Убедиться, что падает.** **Шаг 3: Написать дашборды** по составу из спецификации. **Шаг 4: Тест проходит; Grafana загружает дашборды без ошибок провижининга.**
- [ ] **Шаг 5: Коммит** `IVHR-85 …`.

### Задача 7: Документация

**Файлы:** `deploy.md` (раздел «Наблюдаемость»: подключение оверлея, выдача сертификата `prometheus`, пароль Grafana), `services/README.md` (карта), README изменённых сервисов (список метрик), `infra/observability/README.md`.

- [ ] **Шаг 1:** написать разделы; проверить, что все команды из них выполнимы.
- [ ] **Шаг 2: Коммит** `IVHR-85 …`.

---

## Самопроверка

- Покрытие спецификации: оверлей и агент логов (1), mTLS и сертификат (2), HTTP-метрики (3), бизнес-метрики (4), экспортеры и MinIO (5), семь дашбордов (6), документация (7). Алерты, GPU, трассировка вне плана по спецификации.
- Имена из Задачи 4 используются в Задаче 6 без изменений.
