#!/usr/bin/env bash
# Политика /metrics в прокси сервисов: одноразовый CA, боевые infra/mtls/*.conf, заглушки
# получателей на localhost. prometheus ходит только на GET /metrics; шлюз (nginx) и другие
# сервисы на /metrics получают 403. Основной стек не затрагивается (префикс metricst).
# Код возврата — число провалов.
#
#   infra/observability/tests/metrics_policy.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
P=metricst
export PKI_DIR="$TMP/pki" PKI_CA_CONTAINER="$P-ca" PKI_CA_VOLUME="${P}_ca_data"
source "$REPO/scripts/pki/lib.sh"
NET="$P-net"
PY=python:3.12-slim
SERVICES=(auth-svc chat-svc library-svc db-svc graph-rag-svc embedding-svc)
CLIENTS=(prometheus nginx chat-svc)

cleanup() {
    docker rm -f "$PKI_CA_CONTAINER" "$P-prometheus" >/dev/null 2>&1
    for s in "${SERVICES[@]}"; do docker rm -f "$P-$s" "$P-$s-mtls" >/dev/null 2>&1; docker volume rm -f "${P}_$s" >/dev/null 2>&1; done
    for c in "${CLIENTS[@]}"; do docker volume rm -f "${P}_$c" >/dev/null 2>&1; done
    docker volume rm -f "$PKI_CA_VOLUME" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT
cleanup >/dev/null 2>&1; mkdir -p "$TMP"

"$REPO/scripts/pki/init.sh" >/dev/null 2>&1 || { echo "ПРОВАЛ  init.sh"; exit 1; }
docker network create "$NET" >/dev/null
docker run -d --name "$PKI_CA_CONTAINER" --network "$NET" --network-alias step-ca --entrypoint /bin/sh \
    -e PKI_CERT_TTL=24h -v "$PKI_CA_VOLUME:/home/step" -v "$REPO/infra/pki/entrypoint.sh:/entrypoint.sh:ro" \
    "$STEP_IMAGE" /entrypoint.sh >/dev/null
for _ in $(seq 1 30); do
    docker exec "$PKI_CA_CONTAINER" step ca health --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt >/dev/null 2>&1 && break
    sleep 1
done

# Сертификаты: у сервисов (сервер прокси) и у вызывающих (prometheus, nginx, chat-svc).
for id in "${SERVICES[@]}" "${CLIENTS[@]}"; do
    vol="${P}_$id"
    owner=(); [[ $id == prometheus ]] && owner=(--uid 65534 --gid 65534)  # пользователь образа prometheus
    "$REPO/scripts/pki/enroll.sh" "$id" --volume "$vol" "${owner[@]}" >/dev/null 2>&1 || { echo "ПРОВАЛ  сертификат $id"; exit 1; }
done

for s in "${SERVICES[@]}"; do
    docker run -d --name "$P-$s" --network "$NET" --network-alias "$s" --entrypoint "" \
        -v "$REPO/infra/mtls/tests/receiver_stub.py:/srv/receiver_stub.py:ro" "$PY" python /srv/receiver_stub.py >/dev/null
    docker run -d --name "$P-$s-mtls" --network "container:$P-$s" \
        -v "${P}_$s:/pki-svc:ro" -v "$REPO/infra/mtls/$s.conf:/etc/nginx/conf.d/default.conf:ro" \
        nginx:1.27-alpine >/dev/null
done
sleep 3

fail=0
for s in "${SERVICES[@]}"; do
    docker exec "$P-$s-mtls" nginx -t >/dev/null 2>&1 || { echo "ПРОВАЛ  nginx -t ($s)"; docker exec "$P-$s-mtls" nginx -t 2>&1 | tail -4; fail=$((fail + 1)); }
done

# Общий корень для проверки сертификата сервера лежит в каталоге PKI_DIR.
mounts=(-v "$PKI_DIR/root_ca.crt:/certs/root_ca.crt:ro")
for c in "${CLIENTS[@]}"; do mounts+=(-v "${P}_$c:/certs/$c:ro"); done
out="$(docker run --rm --network "$NET" --entrypoint "" "${mounts[@]}" \
    -v "$HERE/metrics_policy.py:/metrics_policy.py:ro" "$PY" python /metrics_policy.py 2>&1)"
rc=$?
echo "$out"

# Настоящий Prometheus с боевым prometheus.mtls.yml собирает метрики заглушек через прокси.
docker run -d --name "$P-prometheus" --network "$NET" --entrypoint "" \
    -v "$REPO/infra/observability/prometheus/prometheus.mtls.yml:/etc/prometheus/prometheus.yml:ro" \
    -v "${P}_prometheus:/pki-svc:ro" prom/prometheus:v3.1.0 \
    /bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/tmp/prom >/dev/null
up=0
for _ in $(seq 1 40); do
    up=$(docker exec "$P-prometheus" wget -qO- 'http://localhost:9090/api/v1/query?query=count(up%7Bjob%3D%22services%22%7D%3D%3D1)' 2>/dev/null \
        | grep -o '"value":\[[0-9.]*,"[0-9]*"' | grep -o '"[0-9]*"$' | tr -d '"')
    [[ ${up:-0} -eq ${#SERVICES[@]} ]] && break
    sleep 2
done
if [[ ${up:-0} -ne ${#SERVICES[@]} ]]; then
    echo "ПРОВАЛ  prometheus.mtls.yml: собираются ${up:-0} из ${#SERVICES[@]} сервисов"
    docker exec "$P-prometheus" wget -qO- 'http://localhost:9090/api/v1/targets' 2>/dev/null | grep -o '"lastError":"[^"]*"' | sort | uniq -c
    fail=$((fail + 1))
else
    echo "prometheus с prometheus.mtls.yml собирает метрики всех ${#SERVICES[@]} сервисов"
fi

[[ $rc -eq 0 && $fail -eq 0 ]] && echo "ВСЕ ПРОВЕРКИ ПРОШЛИ" || exit $((fail + (rc != 0)))
