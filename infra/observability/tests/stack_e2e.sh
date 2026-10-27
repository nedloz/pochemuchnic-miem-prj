#!/usr/bin/env bash
# Поднимает только сервисы наблюдаемости в отдельном compose-проекте и проверяет:
# конфиг Prometheus, цели host/containers, готовность Loki, datasource Grafana и логи в Loki.
# Основной стек не затрагивается; профили llm и embedding-svc не запускаются.
#   infra/observability/tests/stack_e2e.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."

export COMPOSE_PROFILES=observability
export GRAFANA_ADMIN_PASSWORD="e2e-$RANDOM$RANDOM"
export MONITORING_DB_PASSWORD="mon-$RANDOM$RANDOM"
export GRAFANA_PORT="${GRAFANA_PORT:-3300}"
COMPOSE=(docker compose -p obs-test -f docker-compose.yml -f docker-compose.observability.yml)
SERVICES=(prometheus loki alloy grafana node-exporter cadvisor)

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }
# Запросы идут из контейнера prometheus (busybox wget) по сети проекта. Busybox не резолвит
# имена сервисов при `search .` в resolv.conf хоста (Prometheus сам резолвит нормально),
# поэтому обращаемся по IP контейнера.
ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
net() { docker exec prometheus wget -qO- "$@"; }
wait_for() { # описание, команда...
  local what=$1; shift
  for _ in $(seq 1 60); do "$@" >/dev/null 2>&1 && { ok "$what"; return; }; sleep 2; done
  fail "$what: не дождались"
}

trap '"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true' EXIT

"${COMPOSE[@]}" config -q || fail "docker compose config"
"${COMPOSE[@]}" up -d "${SERVICES[@]}" >/dev/null

docker exec prometheus promtool check config /etc/prometheus/prometheus.yml >/dev/null || fail "promtool check config"
ok "promtool check config"

target_up() { net "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22$1%22%7D" | grep -q '"value":\[[0-9.]*,"1"\]'; }
wait_for "цель node-exporter up" target_up node-exporter
wait_for "цель cadvisor up" target_up cadvisor
wait_for "цель loki up" target_up loki

LOKI=$(ip loki); GRAFANA=$(ip grafana)
loki_ready() { net "http://$LOKI:3100/ready" | grep -q ready; }
wait_for "loki ready" loki_ready

basic=$(printf 'admin:%s' "$GRAFANA_ADMIN_PASSWORD" | base64)
grafana_ds() { net --header "Authorization: Basic $basic" "http://$GRAFANA:3000/api/datasources"; }
grafana_ok() { net "http://$GRAFANA:3000/api/health" | grep -q ok; }
wait_for "grafana отвечает" grafana_ok
ds=$(grafana_ds)
echo "$ds" | grep -q '"uid":"prometheus"' || fail "datasource prometheus не создан"
echo "$ds" | grep -q '"uid":"loki"' || fail "datasource loki не создан"
ok "datasource prometheus и loki созданы"

loki_has_logs() { net "http://$LOKI:3100/loki/api/v1/query_range?query=%7Bservice%3D~%22.%2B%22%7D&limit=5" | grep -q '"values":\[\['; }
wait_for "в Loki есть логи с меткой service" loki_has_logs

# Дашборды: Grafana загрузила все семь из файлов, а запросы PromQL и LogQL синтаксически валидны.
dashboards=$(net --header "Authorization: Basic $basic" "http://$GRAFANA:3000/api/search?type=dash-db")
for uid in overview host chat-rag documents users storage logs; do
  echo "$dashboards" | grep -q "\"uid\":\"pochemuchnik-$uid\"" || fail "Grafana не загрузила дашборд pochemuchnik-$uid"
done
ok "Grafana загрузила 7 дашбордов"
python3 infra/observability/tests/queries_check.py "$LOKI" || fail "запросы дашбордов невалидны"
ok "запросы дашбордов валидны в Prometheus и Loki"

# Недоступные цели (сервисы приложения не подняты) не мешают сбору остальных.
target_up prometheus || fail "собственная цель prometheus не up"
ok "недоступные цели не ломают сбор"

echo "ВСЕ ПРОВЕРКИ ПРОШЛИ"
