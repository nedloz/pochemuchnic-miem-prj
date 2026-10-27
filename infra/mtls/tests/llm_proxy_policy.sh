#!/usr/bin/env bash
# llm-proxy за mTLS (infra/mtls/llm-proxy.conf) и его путь в Ollama по mTLS, на заглушке: настоящего
# Ollama не запускаем. Цепочка как в docker-compose.mtls.yml: graph-rag-svc ──► llm-proxy:8443 ──►
# ollama-mtls:8443 (настоящий infra/mtls/ollama.conf) ──► заглушка на 127.0.0.1:11434. Проверяется,
# что пускается только CN graph-rag-svc и только на POST /v1/chat/completions, что прокси предъявляет
# Ollama свой сертификат (CN llm-proxy) и что обычный HTTP-порт снаружи закрыт.
# CA и сертификаты одноразовые, стек не затрагивается (префикс llmmtlstst). Код возврата — число провалов.
#
#   infra/mtls/tests/llm_proxy_policy.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
P=llmmtlstst
export PKI_DIR="$TMP/pki" PKI_CA_CONTAINER="$P-ca" PKI_CA_VOLUME="${P}_ca_data"
source "$REPO/scripts/pki/lib.sh"
NET="$P-net"
IDS=(ollama llm-proxy graph-rag-svc db-svc)

pass=0; fail=0
expect() {
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "PASS  $1"
    else fail=$((fail + 1)); echo "FAIL  $1: ожидалось '$2', получено '$3'"; fi
}

cleanup() {
    docker rm -f "$PKI_CA_CONTAINER" "$P-ollama" "$P-ollama-mtls" "$P-proxy" >/dev/null 2>&1
    for id in "${IDS[@]}"; do docker volume rm -f "${P}_$id" >/dev/null 2>&1; done
    docker volume rm -f "$PKI_CA_VOLUME" "${P}_config" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT
cleanup >/dev/null 2>&1; mkdir -p "$TMP"

"$REPO/scripts/pki/init.sh" >/dev/null 2>&1 || { echo "FAIL  init.sh"; exit 1; }
docker network create "$NET" >/dev/null
docker run -d --name "$PKI_CA_CONTAINER" --network "$NET" --network-alias step-ca --entrypoint /bin/sh \
    -e PKI_CERT_TTL=24h -v "$PKI_CA_VOLUME:/home/step" -v "$REPO/infra/pki/entrypoint.sh:/entrypoint.sh:ro" \
    "$STEP_IMAGE" /entrypoint.sh >/dev/null
for _ in $(seq 1 30); do
    docker exec "$PKI_CA_CONTAINER" step ca health --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt >/dev/null 2>&1 && break
    sleep 1
done
for id in "${IDS[@]}"; do
    "$REPO/scripts/pki/enroll.sh" "$id" --volume "${P}_$id" >/dev/null 2>&1 || { echo "FAIL  сертификат $id"; exit 1; }
done

# Заглушка Ollama: отвечает путём и моделью из тела.
docker run -d --name "$P-ollama" --network "$NET" --network-alias ollama --entrypoint "" python:3.12-slim \
    python -c "
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)))
        out = json.dumps({'path': self.path, 'model': body.get('model'), 'auth': self.headers.get('Authorization', '-')}).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(out))); self.end_headers(); self.wfile.write(out)
http.server.HTTPServer(('127.0.0.1', 11434), H).serve_forever()" >/dev/null
docker run -d --name "$P-ollama-mtls" --network "container:$P-ollama" -v "${P}_ollama:/pki-svc:ro" \
    -v "$REPO/infra/mtls/ollama.conf:/etc/nginx/conf.d/default.conf:ro" nginx:1.27-alpine >/dev/null

# llm-proxy с теми же монтированиями, что дают docker-compose.yml и docker-compose.mtls.yml вместе.
docker run -d --name "$P-proxy" --network "$NET" --network-alias llm-proxy \
    -e ROUTER_KEY=sk-not-used -e LLM_PROXY_LISTEN=127.0.0.1:8080 \
    -v "$REPO/infra/llm-proxy:/etc/nginx/llm-proxy:ro" \
    -v "$REPO/infra/llm-proxy/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "${P}_config:/etc/llm-proxy" \
    -v "${P}_llm-proxy:/pki-svc:ro" \
    -v "$REPO/infra/mtls/llm-proxy.conf:/etc/nginx/conf.d/mtls.conf:ro" \
    -v "$REPO/infra/llm-proxy/ollama_client_tls.conf:/etc/nginx/llm-proxy-tls/ollama.conf:ro" \
    --entrypoint /bin/sh nginx:1.27-alpine /etc/nginx/llm-proxy/entrypoint.sh nginx -g "daemon off;" >/dev/null
sleep 3
docker exec -i "$P-proxy" sh -c 'cat > /etc/llm-proxy/config.json.tmp && mv /etc/llm-proxy/config.json.tmp /etc/llm-proxy/config.json' <<'EOF'
{"mode": "ollama", "router": {"url": "https://api.polza.ai/v1", "model": "qwen/qwen3.5-9b"}, "ollama": {"url": "https://ollama:8443/v1", "model": "ollama-test-model"}}
EOF

expect "nginx -t (ollama-mtls)" ok "$(docker exec "$P-ollama-mtls" nginx -t >/dev/null 2>&1 && echo ok || echo fail)"
expect "nginx -t (llm-proxy)" ok "$(docker exec "$P-proxy" nginx -t >/dev/null 2>&1 && echo ok || echo fail)"
expect "проверка живости изнутри контейнера (127.0.0.1:8080)" ok \
    "$(docker exec "$P-proxy" wget -qO- http://127.0.0.1:8080/healthz 2>/dev/null | tr -d '\n')"

run_client() {
docker run --rm -i --network "$NET" --entrypoint "" -v "${P}_graph-rag-svc:/c/graph-rag-svc:ro" \
    -v "${P}_db-svc:/c/db-svc:ro" python:3.12-slim python - 2>&1 <<'PYEND'
import http.client, json, socket, ssl

def call(who, method, path, show=False):
    ctx = ssl.create_default_context(cafile="/c/db-svc/root_ca.crt")
    if who:
        ctx.load_cert_chain(f"/c/{who}/tls.crt", f"/c/{who}/tls.key")
    try:
        conn = http.client.HTTPSConnection("llm-proxy", 8443, context=ctx, timeout=8)
        conn.request(method, path, body=json.dumps({"model": "default", "messages": []}),
                     headers={"Content-Type": "application/json", "Authorization": "Bearer client"})
        resp = conn.getresponse()
        data = resp.read()
        if show and resp.status == 200:
            seen = json.loads(data)
            return f"{resp.status}:{seen['path']}:{seen['model']}:{seen['auth']}"
        return resp.status
    except Exception as e:
        return type(e).__name__

print("CHAIN", call("graph-rag-svc", "POST", "/v1/chat/completions", show=True))
r = [
    ("db-svc", call("db-svc", "POST", "/v1/chat/completions")),
    ("models", call("graph-rag-svc", "GET", "/v1/models")),
    ("get", call("graph-rag-svc", "GET", "/v1/chat/completions")),
    ("embeddings", call("graph-rag-svc", "POST", "/v1/embeddings")),
    ("обход", call("graph-rag-svc", "POST", "/v1/chat/completions/../models")),
]
print("RESULT", *[f"{k}={v}" for k, v in r])
nc = call(None, "POST", "/v1/chat/completions")
print("NOCERT", "принято" if nc == 200 else "отказ")
try:
    socket.create_connection(("llm-proxy", 8080), 3).close(); print("PLAIN доступен")
except OSError:
    print("PLAIN отказ")
PYEND
}

out="$(run_client)"
expect "graph-rag-svc ──► llm-proxy ──► ollama по mTLS: путь, модель, без ключа" \
    "CHAIN 200:/v1/chat/completions:ollama-test-model:-" "$(grep -o 'CHAIN.*' <<<"$out")"
expect "политика по CN и методу" "RESULT db-svc=403 models=403 get=403 embeddings=403 обход=403" \
    "$(grep -o 'RESULT.*' <<<"$out")"
expect "без сертификата" "NOCERT отказ" "$(grep -o 'NOCERT.*' <<<"$out")"
expect "порт 8080 снаружи закрыт" "PLAIN отказ" "$(grep -o 'PLAIN.*' <<<"$out")"

# После обновления сертификата llm-proxy-certs шлёт SIGHUP PID 1: nginx перечитывает конфигурацию.
docker exec "$P-proxy" kill -HUP 1
sleep 2
expect "после SIGHUP цепочка работает" "CHAIN 200:/v1/chat/completions:ollama-test-model:-" \
    "$(run_client | grep -o 'CHAIN.*')"

echo
echo "Итого: $pass проверок пройдено, $fail провалено"
exit "$fail"
