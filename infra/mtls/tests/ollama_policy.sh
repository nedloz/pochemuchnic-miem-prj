#!/usr/bin/env bash
# Политика прокси перед Ollama (infra/mtls/ollama.conf) на заглушке: настоящего Ollama не запускаем
# (он тяжёлый и в профиле llm). Заглушка отвечает 200 на любой путь на 127.0.0.1:11434. Проверяется,
# что graph-rag-svc ходит только в API чата, управление моделями и чужие сертификаты закрыты.
# Стек не затрагивается (префикс ollamatst). Код возврата — число провалов.
#
#   infra/mtls/tests/ollama_policy.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
P=ollamatst
export PKI_DIR="$TMP/pki" PKI_CA_CONTAINER="$P-ca" PKI_CA_VOLUME="${P}_ca_data"
source "$REPO/scripts/pki/lib.sh"
NET="$P-net"
IDS=(ollama graph-rag-svc db-svc)

pass=0; fail=0
expect() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  $1: ожидалось '$2', получено '$3'"; fi; }

cleanup() {
    docker rm -f "$PKI_CA_CONTAINER" "$P-ollama" "$P-ollama-mtls" >/dev/null 2>&1
    for id in "${IDS[@]}"; do docker volume rm -f "${P}_$id" >/dev/null 2>&1; done
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
for id in "${IDS[@]}"; do
    "$REPO/scripts/pki/enroll.sh" "$id" --volume "${P}_$id" >/dev/null 2>&1 || { echo "ПРОВАЛ  сертификат $id"; exit 1; }
done

docker run -d --name "$P-ollama" --network "$NET" --network-alias ollama --entrypoint "" python:3.12-slim \
    python -c "
import http.server
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
    do_POST = do_DELETE = do_GET
http.server.HTTPServer(('127.0.0.1', 11434), H).serve_forever()" >/dev/null
docker run -d --name "$P-ollama-mtls" --network "container:$P-ollama" -v "${P}_ollama:/pki-svc:ro" \
    -v "$REPO/infra/mtls/ollama.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine >/dev/null
sleep 3
docker exec "$P-ollama-mtls" nginx -t >/dev/null 2>&1 || { echo "ПРОВАЛ  nginx -t"; fail=$((fail + 1)); }

out="$(docker run --rm -i --network "$NET" --entrypoint "" -v "${P}_graph-rag-svc:/c/graph-rag-svc:ro" -v "${P}_db-svc:/c/db-svc:ro" \
    python:3.12-slim python - 2>&1 <<'PYEND'
import http.client, socket, ssl

def call(who, method, path):
    ctx = ssl.create_default_context(cafile="/c/db-svc/root_ca.crt")
    if who:
        ctx.load_cert_chain(f"/c/{who}/tls.crt", f"/c/{who}/tls.key")
    try:
        conn = http.client.HTTPSConnection("ollama", 8443, context=ctx, timeout=8)
        conn.request(method, path)
        return conn.getresponse().status
    except Exception as e:
        return type(e).__name__

r = [
    ("chat", call("graph-rag-svc", "POST", "/api/chat")),
    ("generate", call("graph-rag-svc", "POST", "/api/generate")),
    ("pull", call("graph-rag-svc", "POST", "/api/pull")),
    ("delete", call("graph-rag-svc", "DELETE", "/api/delete")),
    ("обход", call("graph-rag-svc", "POST", "/api/chat/../pull")),
    ("db-svc", call("db-svc", "POST", "/api/chat")),
]
print("RESULT", *[f"{k}={v}" for k, v in r])
nc = call(None, "POST", "/api/chat")
print("NOCERT", "принято" if nc == 200 else "отказ")
try:
    socket.create_connection(("ollama", 11434), 3).close(); print("DIRECT доступен")
except OSError:
    print("DIRECT отказ")
PYEND
)"
expect "политика по CN" "RESULT chat=200 generate=200 pull=403 delete=403 обход=403 db-svc=403" "$(grep -o 'RESULT.*' <<<"$out")"
expect "без сертификата" "NOCERT отказ" "$(grep -o 'NOCERT.*' <<<"$out")"
expect "порт 11434 мимо прокси" "DIRECT отказ" "$(grep -o 'DIRECT.*' <<<"$out")"

echo
echo "Итого: $pass проверок пройдено, $fail провалено"
exit "$fail"
