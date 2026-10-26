#!/usr/bin/env bash
# Проверка подписанного контекста пользователя: настоящий nginx.conf, заглушки сервисов с
# настоящим модулем подписи/проверки и настоящий код зависимостей каждого сервиса.
# Стек не затрагивается (префикс ucctx), ключи одноразовые. Код возврата — число провалов.
#
#   infra/nginx/tests/user_context_e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
P=ucctx
NET="$P-net"
PY=python:3.12-slim
fail=0
pass=0

cleanup() {
    docker rm -f "$P-nginx" "$P-auth-svc" "$P-chat-svc" "$P-library-svc" "$P-db-svc" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT
cleanup >/dev/null 2>&1; mkdir -p "$TMP"

# --- одноразовые ключи тем же скриптом, что и в проекте ---------------------------------------------
KEYS="$TMP/keys"
mkdir -p "$KEYS"
python3 - "$REPO" "$KEYS" <<'PYEND'
import importlib.util, sys
from pathlib import Path
repo, keys = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("gen", repo / "scripts" / "gen_user_context_keys.py")
gen = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gen)
gen.OUT_DIR = keys
sys.argv = ["gen"]
gen.main()
PYEND
chmod -R a+rX "$KEYS"
MODULE="$REPO/services/auth-svc/app/user_context.py"

echo "== код сервисов-получателей (в образах сервисов)"
svc_check() { # сервис, каталог кода в образе, образ
    docker run --rm --entrypoint "" -w "$2" \
        -v "$REPO/services/$1/app:$2/app:ro" -v "$HERE/service_checks.py:/service_checks.py:ro" \
        -v "$KEYS/master.key:/run/secrets/master:ro" -v "$KEYS/$1.key:/run/secrets/user_context_key:ro" \
        -v "$KEYS/chat-svc.key:/run/secrets/chat-svc.key:ro" \
        -e USER_CONTEXT_AUDIENCE="$1" -e USER_CONTEXT_KEY_FILE=/run/secrets/user_context_key \
        -e PYTHONDONTWRITEBYTECODE=1 "$3" python /service_checks.py "$1" 2>&1
}
for spec in "auth-svc /app main-auth-svc" "chat-svc /app main-chat-svc" "library-svc /code main-library-svc" "db-svc /app main-db-svc"; do
    set -- $spec
    out="$(svc_check "$1" "$2" "$3")"
    if [[ $? -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "$out"; fi
done

echo "== nginx: настоящий конфиг, заглушки сервисов"
docker network create "$NET" >/dev/null
stub() { # имя, режим
    docker run -d --name "$P-$1" --network "$NET" --network-alias "$1" --entrypoint "" \
        -v "$MODULE:/srv/user_context.py:ro" -v "$HERE/stubs.py:/srv/stubs.py:ro" \
        -v "$KEYS/master.key:/run/secrets/master:ro" -v "$KEYS/$1.key:/run/secrets/user_context_key:ro" \
        -e STUB="$2" -e USER_CONTEXT_AUDIENCE="$1" -e USER_CONTEXT_KEY_FILE=/run/secrets/user_context_key \
        -e PYTHONDONTWRITEBYTECODE=1 "$PY" python /srv/stubs.py >/dev/null
}
stub auth-svc auth; stub chat-svc echo; stub library-svc echo; stub db-svc echo
docker run -d --name "$P-nginx" --network "$NET" --network-alias nginx \
    -v "$REPO/infra/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" nginx:1.27-alpine >/dev/null
sleep 3
if ! docker exec "$P-nginx" nginx -t >/dev/null 2>&1; then
    echo "ПРОВАЛ  nginx -t:"; docker exec "$P-nginx" nginx -t 2>&1 | tail -5; fail=$((fail + 1))
fi

out="$(docker run --rm --network "$NET" --entrypoint "" \
    -v "$MODULE:/srv/user_context.py:ro" -v "$HERE/client_checks.py:/client_checks.py:ro" \
    -v "$KEYS/master.key:/run/secrets/master:ro" "$PY" python /client_checks.py 2>&1)"
rc=$?
echo "$out"
if [[ $rc -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); fi

printf '\nИтого: %d блоков пройдено, %d провалено\n' "$pass" "$fail"
exit "$fail"
