#!/usr/bin/env bash
# Экспортёры хранилищ в простом режиме: настоящие postgres (с ролью мониторинга), redis и minio
# в отдельном compose-проекте, шлюз заменён заглушкой со stub_status. Проверяет, что цели
# redis, postgres, nginx, minio собираются, а роль мониторинга не видит данные приложения.
# Настоящий infra/nginx/nginx.conf проверяется командой nginx -t на образе шлюза.
# Основной стек не затрагивается; llm и embedding-svc не запускаются.
#   infra/observability/tests/exporters_e2e.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."

export COMPOSE_PROFILES=observability
export GRAFANA_ADMIN_PASSWORD="e2e-$RANDOM$RANDOM"
export MONITORING_DB_PASSWORD="mon-$RANDOM$RANDOM$RANDOM"
COMPOSE=(docker compose -p obs-test -f docker-compose.yml -f docker-compose.observability.yml
         -f infra/observability/tests/exporters.override.yml)
SERVICES=(postgres redis minio nginx prometheus redis-exporter postgres-exporter nginx-exporter)

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
net() { docker exec prometheus wget -qO- "$@"; }
query() { net "http://localhost:9090/api/v1/query?query=$1"; }
wait_for() {
  local what=$1; shift
  for _ in $(seq 1 90); do "$@" >/dev/null 2>&1 && { ok "$what"; return; }; sleep 2; done
  fail "$what: не дождались"
}

trap '"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true' EXIT

"${COMPOSE[@]}" config -q || fail "docker compose config"
"${COMPOSE[@]}" up -d "${SERVICES[@]}" >/dev/null

metric_is_one() { query "$1" | grep -q '"value":\[[0-9.]*,"1"\]'; }
wait_for "redis_up = 1" metric_is_one 'redis_up'
wait_for "pg_up = 1" metric_is_one 'pg_up'
wait_for "nginx_up = 1" metric_is_one 'nginx_up'
minio_metrics() { query 'count%28%7Bjob%3D%22minio%22%2C__name__%3D~%22minio_.%2B%22%7D%29' | grep -q '"value":\[[0-9.]*,"[1-9]'; }
wait_for "метрики minio собираются" minio_metrics

target_up() { query "up%7Bjob%3D%22$1%22%7D" | grep -q '"value":\[[0-9.]*,"1"\]'; }
for job in redis postgres nginx minio; do target_up "$job" || fail "цель $job не up"; done
ok "цели redis, postgres, nginx, minio в состоянии up"

# Роль мониторинга: видит статистику сервера, но не данные приложения.
psql_admin() { docker exec obs-test-postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$0"' "$1"; }
[[ "$(psql_admin "SELECT pg_has_role('monitoring_user','pg_monitor','member')")" == t ]] || fail "monitoring_user не в pg_monitor"
[[ "$(psql_admin "SELECT has_table_privilege('monitoring_user','auth.users','SELECT')")" == f ]] || fail "monitoring_user читает auth.users"
[[ "$(psql_admin "SELECT rolsuper OR rolcreaterole OR rolcreatedb FROM pg_roles WHERE rolname='monitoring_user'")" == f ]] || fail "monitoring_user привилегирован"
ok "роль мониторинга: pg_monitor, без доступа к auth.users и без привилегий"

# Настоящий конфиг шлюза со stub_status принимается nginx (без запуска сайта).
# Имена апстримов подставляются через --add-host: сеть основного стека для этого не нужна.
docker run --rm --add-host auth-svc:127.0.0.1 --add-host chat-svc:127.0.0.1 \
  --add-host library-svc:127.0.0.1 --add-host db-svc:127.0.0.1 \
  -e NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx -e UPSTREAM_SCHEME=http -e UPSTREAM_PORT=8000 \
  -v "$PWD/infra/nginx/nginx.conf:/etc/nginx/templates/nginx.conf.template:ro" \
  main-nginx:latest nginx -t >/dev/null 2>&1 || fail "nginx -t для infra/nginx/nginx.conf"
ok "nginx -t для infra/nginx/nginx.conf"

echo "ВСЕ ПРОВЕРКИ ПРОШЛИ"
