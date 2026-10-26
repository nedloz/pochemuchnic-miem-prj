#!/bin/sh
# Точка входа контейнера step-ca. Перед запуском применяет срок жизни сертификатов из
# PKI_CERT_TTL к конфигурации, чтобы менять его можно было переменной в .env, не редактируя
# файлы в томе:
#
#   PKI_CERT_TTL=168h docker compose --profile pki up -d step-ca
#
# Срок относится к новым сертификатам; уже выданные живут до своего notAfter. Минимум —
# 5 минут (меньше step-ca не принимает), максимум совпадает со значением по умолчанию, так
# что запросить сертификат дольше, чем задано, нельзя.
set -eu

CONFIG=/home/step/config/ca.json
TTL="${PKI_CERT_TTL:-24h}"

case "$TTL" in
    *[!0-9hms]*|"") echo "PKI_CERT_TTL=$TTL: ожидается длительность вида 24h, 168h, 90m" >&2; exit 1 ;;
esac

tmp="$(mktemp)"
jq --arg ttl "$TTL" '
    def claims: {"minTLSCertDuration": "5m", "maxTLSCertDuration": $ttl, "defaultTLSCertDuration": $ttl};
    .authority.claims = claims
    | .authority.provisioners |= map(.claims = claims)
' "$CONFIG" > "$tmp"
cat "$tmp" > "$CONFIG"
rm -f "$tmp"

echo "step-ca: срок жизни сертификатов $TTL"
exec /usr/local/bin/step-ca "$CONFIG" --password-file /home/step/secrets/password
