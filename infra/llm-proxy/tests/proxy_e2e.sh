#!/usr/bin/env bash
# Сквозная проверка llm-proxy на одноразовых контейнерах: настоящие роутер и Ollama не трогаются,
# вместо них заглушка upstream_stub.py под тремя именами (router-a, router-b, ollama-stub). Прокси
# запускается так же, как в docker-compose.yml (тот же образ, точка входа и монтирования), а
# config.json пишется из другого контейнера через временный файл и mv — как это будет делать
# админка db-svc. Стек не затрагивается (префикс llmproxytst). Код возврата — число провалов.
#
#   bash infra/llm-proxy/tests/proxy_e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
P=llmproxytst
NET="$P-net"
STUB="$P-stub"
PROXY="$P-proxy"
PROXY2="$P-proxy2"
KEY="sk-test-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
URL="http://llm-proxy:8080"
URL2="http://llm-proxy2:8080"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "PASS  $1"
    else fail=$((fail + 1)); echo "FAIL  $1: ожидалось '$2', получено '$3'"; fi
}
# Значение поля key=value из вывода client.py.
field() { grep -m1 "^$1=" <<<"$2" | cut -d= -f2-; }

cleanup() {
    docker rm -f "$STUB" "$PROXY" "$PROXY2" >/dev/null 2>&1
    docker volume rm -f "$P-config" "$P-config2" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

client() { docker exec "$STUB" python /t/client.py "$@" 2>&1; }

# Запись config.json из контейнера-заглушки (он смонтировал оба тома): временный файл и mv.
write_config() {  # write_config /cfg|/cfg2 JSON
    docker exec -i "$STUB" sh -c "cat > $1/config.json.tmp && mv $1/config.json.tmp $1/config.json" <<<"$2"
}

# Прокси с теми же образом, точкой входа и монтированиями, что сервис llm-proxy в docker-compose.yml.
run_proxy() {  # run_proxy ИМЯ АЛИАС ТОМ [docker run ...]
    local name="$1" alias="$2" volume="$3"; shift 3
    docker run -d --name "$name" --network "$NET" --network-alias "$alias" "$@" \
        -e LLM_PROXY_LISTEN=8080 \
        -v "$REPO/infra/llm-proxy:/etc/nginx/llm-proxy:ro" \
        -v "$REPO/infra/llm-proxy/nginx.conf:/etc/nginx/nginx.conf:ro" \
        -v "$volume:/etc/llm-proxy" \
        --entrypoint /bin/sh nginx:1.27-alpine /etc/nginx/llm-proxy/entrypoint.sh nginx -g "daemon off;" >/dev/null
}

wait_healthz() {  # wait_healthz URL
    for _ in $(seq 1 30); do
        [ "$(field status "$(client status GET "$1/healthz")")" = 200 ] && return 0
        sleep 0.5
    done
    return 1
}

# Количество строк в логе прокси, содержащих подстроку.
log_count() { docker logs "$1" 2>&1 | grep -cF -- "$2"; }

CFG_ROUTER_A='{"mode": "router", "router": {"url": "http://router-a:9000/v1", "model": "router-model-1"}, "ollama": {"url": "http://ollama-stub:9000/v1", "model": "ollama-model-1"}}'
CFG_OLLAMA='{"mode": "ollama", "router": {"url": "http://router-a:9000/v1", "model": "router-model-1"}, "ollama": {"url": "http://ollama-stub:9000/v1", "model": "ollama-model-1"}}'
CFG_ROUTER_B='{"mode": "router", "router": {"url": "http://router-b:9000/api/v1/", "model": "router-model-2"}, "ollama": {"url": "http://ollama-stub:9000/v1", "model": "ollama-model-1"}}'
CFG_BAD_MODE='{"mode": "gpt", "router": {"url": "http://router-a:9000/v1", "model": "router-model-1"}, "ollama": {"url": "http://ollama-stub:9000/v1", "model": "ollama-model-1"}}'
CFG_EMPTY_MODEL='{"mode": "ollama", "router": {"url": "http://router-a:9000/v1", "model": "router-model-1"}, "ollama": {"url": "http://ollama-stub:9000/v1", "model": ""}}'
CFG_NXDOMAIN='{"mode": "ollama", "router": {"url": "http://router-a:9000/v1", "model": "router-model-1"}, "ollama": {"url": "http://nosuch.invalid:9000/v1", "model": "ollama-model-1"}}'

# Без этой проверки docker run создал бы на месте недостающего файла пустой каталог (от root).
for f in nginx.conf default.conf.template llm.js config.default.json entrypoint.sh; do
    [ -f "$REPO/infra/llm-proxy/$f" ] || { echo "FAIL  нет infra/llm-proxy/$f"; exit 1; }
done

docker network create "$NET" >/dev/null
docker volume create "$P-config" >/dev/null
docker volume create "$P-config2" >/dev/null
docker run -d --name "$STUB" --network "$NET" \
    --network-alias router-a --network-alias router-b --network-alias ollama-stub \
    -v "$HERE:/t:ro" -v "$P-config:/cfg" -v "$P-config2:/cfg2" \
    python:3.12-slim python -u /t/upstream_stub.py >/dev/null

# --- основной прокси: пустой том, ключ задан ---
run_proxy "$PROXY" llm-proxy "$P-config" -e ROUTER_KEY="$KEY"
if ! wait_healthz "$URL"; then
    echo "FAIL  прокси не поднялся"; docker logs "$PROXY" 2>&1 | tail -20; exit 1
fi
check "GET /healthz → 200" 200 "$(field status "$(client status GET "$URL/healthz")")"
check "config.json создан из config.default.json на пустом томе" same \
    "$(diff -q <(docker exec "$STUB" cat /cfg/config.json) "$REPO/infra/llm-proxy/config.default.json" >/dev/null 2>&1 && echo same || echo differs)"
STARTED="$(docker inspect -f '{{.State.StartedAt}}' "$PROXY")"

# Важно: в режиме по умолчанию запросов не шлём, он указывает на настоящий роутер.
write_config /cfg "$CFG_ROUTER_A"
out="$(client chat "$URL/v1/chat/completions")"
check "router: статус" 200 "$(field status "$out")"
check "router: путь <router.url>/chat/completions" /v1/chat/completions "$(field path "$out")"
check "router: Host по upstream" router-a:9000 "$(field host "$out")"
check "router: model \"default\" заменён на router.model" router-model-1 "$(field model "$out")"
check "router: messages/temperature/max_tokens/stream не изменены" same "$(field rest "$out")"
check "router: Authorization заменён ключом" "Bearer $KEY" "$(field auth "$out")"
check "router: чужой Bearer client не доходит" no "$([ "$(field auth "$out")" = "Bearer client" ] && echo yes || echo no)"

write_config /cfg "$CFG_OLLAMA"
out="$(client chat "$URL/v1/chat/completions")"
check "ollama (горячая смена режима): статус" 200 "$(field status "$out")"
check "ollama: другой upstream" ollama-stub:9000 "$(field host "$out")"
check "ollama: путь" /v1/chat/completions "$(field path "$out")"
check "ollama: модель режима" ollama-model-1 "$(field model "$out")"
check "ollama: без Authorization" - "$(field auth "$out")"
check "ollama: остальное тело не изменено" same "$(field rest "$out")"

write_config /cfg "$CFG_ROUTER_B"
out="$(client chat "$URL/v1/chat/completions")"
check "горячая смена router.url и модели: upstream" router-b:9000 "$(field host "$out")"
check "горячая смена router.url: путь (лишний / в конце url убран)" /api/v1/chat/completions "$(field path "$out")"
check "горячая смена: модель" router-model-2 "$(field model "$out")"
check "горячая смена: ключ на месте" "Bearer $KEY" "$(field auth "$out")"
check "контейнер не перезапускался" "$STARTED 0" \
    "$(docker inspect -f '{{.State.StartedAt}} {{.RestartCount}}' "$PROXY")"

# --- некорректный файл: работаем по последней корректной конфигурации ---
check "до порчи файла ошибок конфигурации в логе нет" 0 "$(log_count "$PROXY" "config.json некорректен")"
write_config /cfg '{"mode": "ollama", "router": '
out="$(client chat "$URL/v1/chat/completions")"
check "битый JSON: запрос проходит" 200 "$(field status "$out")"
check "битый JSON: по последней корректной конфигурации" "router-b:9000 router-model-2" \
    "$(field host "$out") $(field model "$out")"
n_bad="$(log_count "$PROXY" "config.json некорректен")"
check "битый JSON: ошибка в логе" yes "$([ "$n_bad" -ge 1 ] && echo yes || echo no)"

write_config /cfg "$CFG_BAD_MODE"
out="$(client chat "$URL/v1/chat/completions")"
check "неизвестный mode: по последней корректной конфигурации" "200 router-b:9000 router-model-2" \
    "$(field status "$out") $(field host "$out") $(field model "$out")"
check "неизвестный mode: ошибка в логе" yes \
    "$([ "$(log_count "$PROXY" "config.json некорректен")" -gt "$n_bad" ] && echo yes || echo no)"

write_config /cfg "$CFG_EMPTY_MODEL"
out="$(client chat "$URL/v1/chat/completions")"
check "пустая модель активного режима: по последней корректной" "200 router-b:9000 router-model-2" \
    "$(field status "$out") $(field host "$out") $(field model "$out")"

# --- SSE: события приходят по мере генерации (заглушка шлёт три события с паузой 1 с) ---
write_config /cfg "$CFG_ROUTER_B"
out="$(client stream "$URL/v1/chat/completions")"
check "SSE: статус" 200 "$(field status "$out")"
check "SSE: три события" 3 "$(field events "$out")"
check "SSE: первое событие раньше конца ответа (без буферизации)" yes \
    "$(awk -v f="$(field first "$out")" -v t="$(field total "$out")" 'BEGIN { print (f >= 0 && f < 0.8 && t >= 1.8) ? "yes" : "no" }')"

# --- запрещённые пути и методы ---
check "GET /v1/models → 403" 403 "$(field status "$(client status GET "$URL/v1/models")")"
check "POST /v1/embeddings → 403" 403 "$(field status "$(client status POST "$URL/v1/embeddings")")"
check "GET /v1/chat/completions → 403" 403 "$(field status "$(client status GET "$URL/v1/chat/completions")")"
check "обход через /v1/chat/completions/../models → 403" 403 \
    "$(field status "$(client status POST "$URL/v1/chat/completions/../models")")"
check "тело не JSON → 400" 400 \
    "$(field status "$(docker exec -e BODY='не json' "$STUB" python /t/client.py status POST "$URL/v1/chat/completions" 2>&1)")"

# --- upstream не разрешается: 502, прокси жив ---
write_config /cfg "$CFG_NXDOMAIN"
check "upstream без DNS-имени → 502" 502 "$(field status "$(client status POST "$URL/v1/chat/completions")")"
check "после 502 прокси работает" "true 200" \
    "$(docker inspect -f '{{.State.Running}}' "$PROXY") $(field status "$(client status GET "$URL/healthz")")"

# --- второй прокси: корректного файла нет с самого старта, ключ не задан ---
write_config /cfg2 '{"mode": "router", '
run_proxy "$PROXY2" llm-proxy2 "$P-config2"
if wait_healthz "$URL2"; then
    check "битый файл со старта: /healthz → 200" 200 "$(field status "$(client status GET "$URL2/healthz")")"
    check "битый файл со старта: /v1/chat/completions → 503" 503 \
        "$(field status "$(client chat "$URL2/v1/chat/completions")")"
    check "точка входа не перезаписывает существующий файл" '{"mode": "router", ' "$(docker exec "$STUB" cat /cfg2/config.json)"
    docker exec "$STUB" rm -f /cfg2/config.json
    check "файла нет: /v1/chat/completions → 503" 503 "$(field status "$(client chat "$URL2/v1/chat/completions")")"
    write_config /cfg2 "$CFG_OLLAMA"
    out="$(client chat "$URL2/v1/chat/completions")"
    check "появился корректный файл: работает без перезапуска" "200 ollama-stub:9000" "$(field status "$out") $(field host "$out")"
    write_config /cfg2 "$CFG_ROUTER_A"
    check "router без ROUTER_KEY → 503" 503 "$(field status "$(client chat "$URL2/v1/chat/completions")")"
    check "router без ROUTER_KEY: причина в логе" yes \
        "$([ "$(log_count "$PROXY2" "ROUTER_KEY не задан")" -ge 1 ] && echo yes || echo no)"
else
    check "второй прокси поднялся" ok fail
fi

# --- секреты и тела запросов не попадают в логи и файлы ---
logs="$(docker logs "$PROXY" 2>&1; docker logs "$PROXY2" 2>&1)"
check "в логах нет ключа" 0 "$(grep -cF -- "$KEY" <<<"$logs")"
check "в логах нет чужого Authorization" 0 "$(grep -cF -- "Bearer client" <<<"$logs")"
check "в логах нет тел запросов" 0 "$(grep -cF -- "маркер-тела-7f3a" <<<"$logs")"
check "ключа нет в файлах /etc/nginx и /etc/llm-proxy" 0 \
    "$(docker exec "$PROXY" grep -rlF -- "$KEY" /etc/nginx /etc/llm-proxy 2>/dev/null | wc -l)"

echo
echo "Итого: $pass проверок пройдено, $fail провалено"
exit "$fail"
