#!/usr/bin/env bash
# Самопроверка внутреннего центра сертификации: поднимает отдельный одноразовый CA (свои сеть,
# тома и контейнеры с префиксом pkiselftest, настоящий CA не затрагивается), выдаёт сертификаты
# и проверяет всё, что от них ожидается: цепочку, срок жизни, привязку токена к имени,
# одноразовость токена, обновление, взаимную TLS-аутентификацию. Код возврата — число провалов.
#
#   infra/pki/tests/selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
P=pkiselftest

export PKI_DIR="$TMP/pki" PKI_CA_CONTAINER="$P-ca" PKI_CA_VOLUME="${P}_ca_data"
source "$REPO_ROOT/scripts/pki/lib.sh"
NET="${P}-net"

pass=0; fail=0
check() { # описание, команда...
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  $desc"; fi
}
check_not() { # описание, команда... (должна завершиться ошибкой)
    local desc=$1; shift
    if "$@" >/dev/null 2>&1; then fail=$((fail + 1)); echo "ПРОВАЛ  $desc"; else pass=$((pass + 1)); fi
}

cleanup() {
    docker rm -f "$PKI_CA_CONTAINER" "$P-srv" >/dev/null 2>&1
    docker volume rm -f "$PKI_CA_VOLUME" "${P}_alpha" "${P}_beta" "${P}_gamma" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT
cleanup >/dev/null 2>&1; mkdir -p "$TMP"

start_ca() { # TTL
    docker rm -f "$PKI_CA_CONTAINER" >/dev/null 2>&1
    docker run -d --name "$PKI_CA_CONTAINER" --network "$NET" --network-alias step-ca \
        --entrypoint /bin/sh -e PKI_CERT_TTL="$1" -v "$PKI_CA_VOLUME:/home/step" \
        -v "$REPO_ROOT/infra/pki/entrypoint.sh:/entrypoint.sh:ro" "$STEP_IMAGE" /entrypoint.sh >/dev/null
    for _ in $(seq 1 30); do
        docker exec "$PKI_CA_CONTAINER" step ca health --ca-url https://localhost:9000 \
            --root /home/step/certs/root_ca.crt >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}
# Файлы сертификата из тома наружу (для проверок openssl на хосте).
export_certs() { # том, каталог
    mkdir -p "$2"
    docker run --rm --entrypoint "" --user 0 -v "$1:/certs:ro" -v "$2:/out" "$STEP_IMAGE" sh -c \
        'cp /certs/tls.crt /certs/tls.key /certs/root_ca.crt /out/ && chmod 644 /out/*'
}
mint_token() { # имя, san...
    local name=$1; shift
    local args=(); for s in "$@"; do args+=(--san "$s"); done
    docker exec "$PKI_CA_CONTAINER" step ca token "$name" "${args[@]}" --issuer "$PKI_PROVISIONER" \
        --key /home/step/secrets/provisioner_key.json --password-file /home/step/secrets/provisioner_password \
        --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt
}
use_token() { # имя, токен
    printf '%s\n' "$2" | docker run --rm -i --entrypoint "" --network "$NET" -e STEPPATH=/tmp/step \
        -v "$PKI_DIR/root_ca.crt:/root_ca.crt:ro" "$STEP_IMAGE" sh -ec \
        "read -r T; step ca certificate '$1' /tmp/c.crt /tmp/c.key --token \"\$T\" --ca-url https://step-ca:9000 --root /root_ca.crt"
}

echo "== центр сертификации"
"$REPO_ROOT/scripts/pki/init.sh" >/dev/null 2>&1 || { echo "ПРОВАЛ  init.sh"; exit 1; }
docker network create "$NET" >/dev/null
start_ca 24h || { echo "ПРОВАЛ  CA не запустился"; docker logs "$PKI_CA_CONTAINER" 2>&1 | tail; exit 1; }

ROOT="$PKI_DIR/root_ca.crt"
check "корневой ключ не попал в том CA" \
    bash -c "! docker run --rm --entrypoint '' -v '$PKI_CA_VOLUME:/h:ro' '$STEP_IMAGE' find /h -name 'root_ca.key' | grep -q ."
check "промежуточный CA не может выпускать подчинённые CA (pathlen:0)" \
    bash -c "docker run --rm --entrypoint '' -v '$PKI_CA_VOLUME:/h:ro' '$STEP_IMAGE' step certificate inspect /h/certs/intermediate_ca.crt | grep -q 'CA:TRUE, pathlen:0'"

echo "== выдача"
"$REPO_ROOT/scripts/pki/enroll.sh" alpha --san localhost --uid 1234 --gid 1234 --volume "${P}_alpha" >/dev/null 2>&1
"$REPO_ROOT/scripts/pki/enroll.sh" beta --volume "${P}_beta" >/dev/null 2>&1
export_certs "${P}_alpha" "$TMP/alpha"; export_certs "${P}_beta" "$TMP/beta"

# tls.crt содержит лист и промежуточный сертификат; корень проверяющий знает заранее.
verify() { openssl verify -CAfile "$ROOT" -untrusted "$1" "$1"; }
check "цепочка alpha проверяется по корню" verify "$TMP/alpha/tls.crt"
check "alpha: имена CN и SAN" bash -c "openssl x509 -in '$TMP/alpha/tls.crt' -noout -text | grep -q 'DNS:alpha' && openssl x509 -in '$TMP/alpha/tls.crt' -noout -text | grep -q 'DNS:localhost' && openssl x509 -in '$TMP/alpha/tls.crt' -noout -subject | grep -q 'CN *= *alpha'"
check "alpha: годится и для сервера, и для клиента" bash -c "openssl x509 -in '$TMP/alpha/tls.crt' -noout -text | grep -q 'TLS Web Server Authentication' && openssl x509 -in '$TMP/alpha/tls.crt' -noout -text | grep -q 'TLS Web Client Authentication'"
not_before=$(date -d "$(openssl x509 -in "$TMP/alpha/tls.crt" -noout -startdate | cut -d= -f2)" +%s)
not_after=$(date -d "$(openssl x509 -in "$TMP/alpha/tls.crt" -noout -enddate | cut -d= -f2)" +%s)
check "срок жизни по умолчанию 24 часа (получено $(( (not_after - not_before) / 3600 )) ч)" test $(( (not_after - not_before) / 3600 )) -eq 24
check "владелец и права файлов заданы (uid 1234, ключ 0600)" bash -c \
    "docker run --rm --entrypoint '' -v '${P}_alpha:/c:ro' '$STEP_IMAGE' sh -c '[ \"\$(stat -c %u:%a /c/tls.key)\" = 1234:600 ]'"

echo "== токены"
TOKEN="$(mint_token alpha alpha)"
check_not "токен для alpha не даёт сертификат beta" use_token beta "$TOKEN"
TOKEN="$(mint_token alpha alpha)"
check "токен для alpha даёт сертификат alpha" use_token alpha "$TOKEN"
check_not "использованный токен повторно не принимается" use_token alpha "$TOKEN"
check_not "подделанный токен не принимается" use_token alpha "${TOKEN%?}x"

echo "== обновление"
serial_before=$(openssl x509 -in "$TMP/alpha/tls.crt" -noout -serial)
sleep 2
docker run --rm --entrypoint "" --user 0 --network "$NET" -v "${P}_alpha:/certs" "$STEP_IMAGE" \
    step ca renew --force --ca-url https://step-ca:9000 --root /certs/root_ca.crt /certs/tls.crt /certs/tls.key >/dev/null 2>&1
export_certs "${P}_alpha" "$TMP/alpha2"
check "обновление выпустило новый сертификат" test "$serial_before" != "$(openssl x509 -in "$TMP/alpha2/tls.crt" -noout -serial)"
check "обновлённый сертификат проверяется по корню" verify "$TMP/alpha2/tls.crt"
check "обновление сохранило владельца и права ключа" bash -c \
    "docker run --rm --entrypoint '' -v '${P}_alpha:/c:ro' '$STEP_IMAGE' sh -c '[ \"\$(stat -c %u:%a /c/tls.key)\" = 1234:600 ]'"
mkdir -p "$TMP/rogue" && openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$TMP/rogue/c.key" -out "$TMP/rogue/c.crt" -subj "/CN=alpha" -addext "subjectAltName=DNS:alpha" -days 1 >/dev/null 2>&1
cp "$ROOT" "$TMP/rogue/ca.crt"; chmod -R a+rX "$TMP/rogue"
check_not "самоподписанный «alpha» не может обновиться" bash -c \
    "docker run --rm --entrypoint '' --user 0 --network '$NET' -v '$TMP/rogue:/r' '$STEP_IMAGE' step ca renew --force --ca-url https://step-ca:9000 --root /r/ca.crt /r/c.crt /r/c.key"
check "обновление реальным сертификатом на тех же аргументах проходит (контроль)" bash -c \
    "docker run --rm --entrypoint '' --user 0 --network '$NET' -v '${P}_beta:/r' '$STEP_IMAGE' step ca renew --force --ca-url https://step-ca:9000 --root /r/root_ca.crt /r/tls.crt /r/tls.key"

echo "== взаимная TLS-аутентификация"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$TMP/rogue.key" -out "$TMP/rogue.crt" -subj "/CN=beta" -days 1 >/dev/null 2>&1
handshake() { # каталог сертификата сервера; клиентские параметры...
    local srv=$1; shift
    local port=$((20000 + RANDOM % 20000))
    openssl s_server -accept "$port" -cert "$srv/tls.crt" -cert_chain "$srv/tls.crt" -key "$srv/tls.key" -CAfile "$ROOT" -Verify 1 \
        -verify_return_error -www -naccept 1 >/dev/null 2>&1 &
    local pid=$!
    sleep 1
    local out
    # stdin держится открытым пару секунд: иначе s_client закрывает соединение раньше ответа.
    out="$( (printf 'GET / HTTP/1.0\r\n\r\n'; sleep 2) | timeout 8 openssl s_client -connect "localhost:$port" -CAfile "$ROOT" \
        -verify_return_error -verify_hostname localhost "$@" 2>&1)"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    printf '%s\n' "$out" > "$TMP/handshake.log"
    grep -q "HTTP/1.0 200" <<<"$out"
}
check "beta (клиент) → alpha (сервер): принято" handshake "$TMP/alpha" -cert "$TMP/beta/tls.crt" -cert_chain "$TMP/beta/tls.crt" -key "$TMP/beta/tls.key"
[[ -n "${SELFTEST_DEBUG:-}" ]] && { echo "--- вывод s_client (beta → alpha):"; tail -25 "$TMP/handshake.log"; }
check_not "клиент без сертификата отвергнут" handshake "$TMP/alpha"
check_not "клиент с сертификатом чужого CA отвергнут" handshake "$TMP/alpha" -cert "$TMP/rogue.crt" -key "$TMP/rogue.key"

echo "== срок жизни из PKI_CERT_TTL"
start_ca 168h || { fail=$((fail + 1)); echo "ПРОВАЛ  CA не запустился с 168h"; }
"$REPO_ROOT/scripts/pki/enroll.sh" gamma --volume "${P}_gamma" >/dev/null 2>&1
export_certs "${P}_gamma" "$TMP/gamma"
nb=$(date -d "$(openssl x509 -in "$TMP/gamma/tls.crt" -noout -startdate | cut -d= -f2)" +%s)
na=$(date -d "$(openssl x509 -in "$TMP/gamma/tls.crt" -noout -enddate | cut -d= -f2)" +%s)
check "после смены PKI_CERT_TTL=168h новые сертификаты живут 7 суток (получено $(( (na - nb) / 3600 )) ч)" test $(( (na - nb) / 3600 )) -eq 168
check "ранее выданные сертификаты продолжают работать" verify "$TMP/alpha/tls.crt"
docker rm -f "$PKI_CA_CONTAINER" >/dev/null 2>&1
check_not "некорректный PKI_CERT_TTL останавливает запуск" bash -c \
    "docker run --rm --entrypoint /bin/sh -e PKI_CERT_TTL='24 hours' -v '$PKI_CA_VOLUME:/home/step' -v '$REPO_ROOT/infra/pki/entrypoint.sh:/entrypoint.sh:ro' '$STEP_IMAGE' /entrypoint.sh"

printf '\nИтого: %d проверок пройдено, %d провалено\n' "$pass" "$fail"
exit "$fail"
