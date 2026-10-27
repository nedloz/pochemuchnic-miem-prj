#!/usr/bin/env bash
# Проверка MinIO за mTLS-прокси: настоящий MinIO (образ из docker-compose.yml), nginx с боевым
# шаблоном infra/mtls/minio.conf и настоящий клиентский код library-svc (minio-py), db-svc (boto3)
# и ingest-worker (aioboto3). Стек не затрагивается (префикс miniotst). Код возврата — число провалов.
#
#   infra/mtls/tests/minio_e2e.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
TMP="$(mktemp -d)"
P=miniotst
export PKI_DIR="$TMP/pki" PKI_CA_CONTAINER="$P-ca" PKI_CA_VOLUME="${P}_ca_data"
source "$REPO/scripts/pki/lib.sh"
NET="$P-net"
IDS=(minio library-svc db-svc ingest-worker graph-rag-svc prometheus)
IMAGE="$(grep -oE 'chainguard/minio@sha256:[0-9a-f]+' "$REPO/docker-compose.yml" | head -1)"
BUCKET=documents
KEY="k$(head -c6 /dev/urandom | od -An -tx1 | tr -d ' \n')"; SECRET="s$(head -c18 /dev/urandom | od -An -tx1 | tr -d ' \n')"

pass=0; fail=0
expect() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "ПРОВАЛ  $1: ожидалось '$2', получено '$3'"; tail -n 6 <<<"${out:-}" | sed 's/^/        /'; fi; }

cleanup() {
    docker rm -f "$PKI_CA_CONTAINER" "$P-minio" "$P-minio-mtls" >/dev/null 2>&1
    for id in "${IDS[@]}"; do docker volume rm -f "${P}_$id" >/dev/null 2>&1; done
    docker volume rm -f "$PKI_CA_VOLUME" "${P}_data" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT
cleanup >/dev/null 2>&1; mkdir -p "$TMP"

echo "== центр сертификации и сертификаты"
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

echo "== MinIO + прокси с боевым шаблоном"
docker run -d --name "$P-minio" --network "$NET" --network-alias minio --user 0:0 -v "${P}_data:/data" \
    -e MINIO_ROOT_USER="$KEY" -e MINIO_ROOT_PASSWORD="$SECRET" -e MINIO_PROMETHEUS_AUTH_TYPE=public "$IMAGE" \
    server /data --address 127.0.0.1:9000 --console-address 127.0.0.1:9001 >/dev/null
docker run -d --name "$P-minio-mtls" --network "container:$P-minio" -e MINIO_BUCKET="$BUCKET" -v "${P}_minio:/pki-svc:ro" \
    -v "$REPO/infra/mtls/minio.conf:/etc/nginx/templates/default.conf.template:ro" nginx:1.27-alpine >/dev/null
for _ in $(seq 1 30); do
    docker exec "$P-minio" bash -c "exec 3<>/dev/tcp/127.0.0.1/9000" >/dev/null 2>&1 && break
    sleep 1
done
sleep 2
docker exec "$P-minio-mtls" nginx -t >/dev/null 2>&1 || { echo "ПРОВАЛ  nginx -t"; docker exec "$P-minio-mtls" nginx -t 2>&1 | tail -3; fail=$((fail + 1)); }

run_py() { # образ, монтирование кода, рабочий каталог, том сертификата; код на stdin
    local image=$1 code=$2 wd=$3 vol=$4; shift 4
    docker run --rm -i --network "$NET" --entrypoint "" -w "$wd" -e PYTHONDONTWRITEBYTECODE=1 \
        -v "$code" -v "$vol:/pki-svc:ro" \
        -e SERVICE_MTLS_CERT=/pki-svc/tls.crt -e SERVICE_MTLS_KEY=/pki-svc/tls.key -e SERVICE_MTLS_CA=/pki-svc/root_ca.crt \
        -e MINIO_ENDPOINT=minio:8443 -e MINIO_SECURE=true -e MINIO_ACCESS_KEY="$KEY" -e MINIO_SECRET_KEY="$SECRET" \
        -e DATABASE_URL=postgresql+asyncpg://x@localhost/x -e MINIO_BUCKET="$BUCKET" -e S3_ENDPOINT=https://minio:8443 -e S3_ACCESS_KEY="$KEY" -e S3_SECRET_KEY="$SECRET" \
        "$@" "$image" python - 2>&1
}
res() { grep -o 'RESULT.*' <<<"$1" | head -1; }
LIB="$REPO/services/library-svc/app:/code/app:ro"
DBS="$REPO/services/db-svc/app:/app/app:ro"
ING="$REPO/services/ingest-worker/app:/app/app:ro"

echo "== db-svc (boto3): чтение и запись"
out="$(run_py main-db-svc "$DBS" /app "${P}_db-svc" <<'PYEND'
from app.routes.minio import s3_client, ensure_bucket
c = s3_client()
b = ensure_bucket(c)
c.put_object(Bucket=b, Key="dir/file.txt", Body=b"hello")
body = c.get_object(Bucket=b, Key="dir/file.txt")["Body"].read()
names = [x["Name"] for x in c.list_buckets()["Buckets"]]
c.put_object(Bucket=b, Key="tmp.txt", Body=b"x"); c.delete_object(Bucket=b, Key="tmp.txt")
print("RESULT", body.decode(), b in names)
PYEND
)"
expect "db-svc: put/get/delete/list_buckets через mTLS ($(res "$out"))" "RESULT hello True" "$(res "$out")"

echo "== library-svc (minio-py): только чтение"
out="$(run_py main-library-svc "$LIB" /code "${P}_library-svc" <<'PYEND'
from app.services import get_minio_client
c = get_minio_client()
data = c.get_object("documents", "dir/file.txt").read()
st = c.stat_object("documents", "dir/file.txt").size
try:
    import io
    c.put_object("documents", "evil.txt", io.BytesIO(b"x"), 1); w = "записал"
except Exception as e:
    w = "запись отказ " + ("403" if "403" in str(e) or "AccessDenied" in str(e) else str(e)[:40])
print("RESULT", data.decode(), st, w)
PYEND
)"
expect "library-svc: чтение да, запись нет ($(res "$out"))" "RESULT hello 5 запись отказ 403" "$(res "$out")"

echo "== ingest-worker (aioboto3): только чтение"
out="$(run_py main-ingest-worker "$ING" /app/app "${P}_ingest-worker" <<'PYEND'
import asyncio, os
os.environ.setdefault("S3_ENDPOINT", "https://minio:8443")
import parsers, aioboto3
from aiobotocore.config import AioConfig
import s3_tls
async def main():
    got = await parsers.get_content_from_s3("documents", "dir/file.txt")
    session = aioboto3.Session()
    async with session.client("s3", endpoint_url=parsers.S3_ENDPOINT, aws_access_key_id=parsers.S3_ACCESS_KEY,
                              aws_secret_access_key=parsers.S3_SECRET_KEY, verify=s3_tls.verify(),
                              config=AioConfig(client_cert=s3_tls.client_cert())) as s3:
        try:
            await s3.put_object(Bucket="documents", Key="evil.txt", Body=b"x"); w = "записал"
        except Exception as e:
            w = "запись отказ " + ("403" if "403" in str(e) or "AccessDenied" in str(e) else str(e)[:40])
    print("RESULT", got.decode(), w)
asyncio.run(main())
PYEND
)"
expect "ingest-worker: чтение да, запись нет ($(res "$out"))" "RESULT hello запись отказ 403" "$(res "$out")"

echo "== политика, чужие сертификаты и обход прокси"
out="$(docker run --rm -i --network "$NET" --entrypoint "" -v "${P}_graph-rag-svc:/c/graph-rag-svc:ro" -v "${P}_library-svc:/c/library-svc:ro" \
    -v "${P}_db-svc:/c/db-svc:ro" -v "${P}_prometheus:/c/prometheus:ro" -e "AK=$KEY" -e "SK=$SECRET" main-db-svc python - 2>&1 <<'PYEND'
import http.client, os, socket, ssl

def call(who, method, path):
    ctx = ssl.create_default_context(cafile="/c/db-svc/root_ca.crt")
    if who:
        ctx.load_cert_chain(f"/c/{who}/tls.crt", f"/c/{who}/tls.key")
    try:
        conn = http.client.HTTPSConnection("minio", 8443, context=ctx, timeout=8)
        conn.request(method, path)
        return conn.getresponse().status
    except Exception as e:
        return type(e).__name__

r = {
    "graph-rag-svc читает": call("graph-rag-svc", "GET", "/documents/dir/file.txt"),
    "library-svc DELETE": call("library-svc", "DELETE", "/documents/dir/file.txt"),
    "library-svc чужой бакет": call("library-svc", "GET", "/other/x"),
    "library-svc обход пути": call("library-svc", "GET", "/documents/../other/x"),
    "library-svc список бакетов": call("library-svc", "GET", "/"),
    "db-svc чужой бакет": call("db-svc", "PUT", "/other/x"),
    "консоль": call("db-svc", "GET", "/minio/health/live"),
    "prometheus метрики кластера": call("prometheus", "GET", "/minio/v2/metrics/cluster"),
    "prometheus метрики узла": call("prometheus", "GET", "/minio/v2/metrics/node"),
    "prometheus читает объект": call("prometheus", "GET", "/documents/dir/file.txt"),
    "prometheus пишет метрики": call("prometheus", "PUT", "/minio/v2/metrics/cluster"),
    "prometheus обход пути": call("prometheus", "GET", "/minio/v2/metrics/cluster/../../../documents/dir/file.txt"),
    "library-svc метрики": call("library-svc", "GET", "/minio/v2/metrics/cluster"),
}
print("RESULT", *[f"{k}={v}" for k, v in r.items()])
nc = call(None, "GET", "/documents/dir/file.txt")
print("NOCERT", nc if isinstance(nc, str) or nc != 200 else "принято")
for port in (9000, 9001):
    try:
        socket.create_connection(("minio", port), 3).close(); print(f"DIRECT {port} доступен")
    except OSError:
        print(f"DIRECT {port} отказ")
PYEND
)"
expect "политика по CN" "RESULT graph-rag-svc читает=403 library-svc DELETE=403 library-svc чужой бакет=403 library-svc обход пути=403 library-svc список бакетов=403 db-svc чужой бакет=403 консоль=403 prometheus метрики кластера=200 prometheus метрики узла=200 prometheus читает объект=403 prometheus пишет метрики=403 prometheus обход пути=403 library-svc метрики=403" "$(res "$out")"
nocert="$(grep -o 'NOCERT.*' <<<"$out")"
[[ "$nocert" != *принято* && -n "$nocert" ]] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "ПРОВАЛ  без клиентского сертификата: $nocert"; }
expect "порт 9000 мимо прокси" "DIRECT 9000 отказ" "$(grep -o 'DIRECT 9000.*' <<<"$out")"
expect "порт консоли 9001" "DIRECT 9001 отказ" "$(grep -o 'DIRECT 9001.*' <<<"$out")"

echo "== слабые ключи по умолчанию не подходят"
out="$(run_py main-db-svc "$DBS" /app "${P}_db-svc" -e MINIO_ACCESS_KEY=minioadmin -e MINIO_SECRET_KEY=minioadmin <<'PYEND'
from app.routes.minio import s3_client
try:
    s3_client().list_buckets(); print("RESULT принято")
except Exception as e:
    print("RESULT отказ")
PYEND
)"
expect "minioadmin/minioadmin отвергнуты" "RESULT отказ" "$(res "$out")"

echo
echo "Итого: $pass проверок пройдено, $fail провалено"
exit "$fail"
