#!/bin/sh
# Точка входа контейнера, который держит сертификат сервиса свежим. Запускается рядом с
# сервисом (в Kubernetes это будет sidecar), читает и пишет общий том с сертификатом.
#
# Обновление идёт по существующему сертификату (mTLS к CA), токены больше не нужны: они
# требуются только для первой выдачи (scripts/pki/enroll.sh). Если сертификат успел истечь
# (стек простоял дольше срока жизни), обновить его уже нельзя — нужна повторная выдача.
#
# Переменные:
#   CA_URL    адрес CA                                   (по умолчанию https://step-ca:9000)
#   CERT_DIR  каталог с tls.crt, tls.key, root_ca.crt     (по умолчанию /certs)
#   RENEW_EXEC  команда, выполняемая после каждого обновления (например, перечитать конфиг сервиса)
set -eu

CA_URL="${CA_URL:-https://step-ca:9000}"
CERT_DIR="${CERT_DIR:-/certs}"

set -- step ca renew --daemon --ca-url "$CA_URL" --root "$CERT_DIR/root_ca.crt"
[ -n "${RENEW_EXEC:-}" ] && set -- "$@" --exec "$RENEW_EXEC"
exec "$@" "$CERT_DIR/tls.crt" "$CERT_DIR/tls.key"
