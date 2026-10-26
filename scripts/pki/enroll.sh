#!/usr/bin/env bash
# Выдаёт сертификат сервису: тот самый «первый» сертификат, для которого нужен токен.
# Дальнейшее обновление идёт без токенов (infra/pki/renewer.sh).
#
#   scripts/pki/enroll.sh <имя> [--san ещё.имя]... [--uid N] [--gid N] [--volume ТОМ]
#
#   <имя>      идентичность сервиса: попадает в CN и SAN сертификата (chat-svc, postgres, ...);
#              именно по ней другие сервисы решают, кого они видят перед собой
#   --san      дополнительные имена, по которым сервис доступен (localhost, алиасы)
#   --uid/gid  владелец файлов в томе (по умолчанию 0); ключ создаётся с правами 0600
#   --volume   том для сертификата (по умолчанию pki_certs_<имя>)
#
# Как это устроено. Токен — одноразовый JWT на 5 минут, подписанный ключом провизионера и
# содержащий допустимые имена. CA выдаст сертификат только на эти имена, поэтому токен,
# выпущенный для chat-svc, бесполезен для получения сертификата postgres, а украденный после
# использования — для чего угодно. Ключом провизионера владеет тот, кто может выполнять
# docker exec в контейнер CA, то есть оператор.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ $# -ge 1 ]] || die "использование: $0 <имя> [--san имя]... [--uid N] [--gid N] [--volume ТОМ]"
NAME="$1"; shift
[[ "$NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9._-]*[a-zA-Z0-9])?$ ]] || die "недопустимое имя: $NAME"

SANS=("$NAME")
OWNER_UID=0
OWNER_GID=0
VOLUME="pki_certs_$NAME"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --san) SANS+=("$2"); shift 2 ;;
        --uid) OWNER_UID="$2"; shift 2 ;;
        --gid) OWNER_GID="$2"; shift 2 ;;
        --volume) VOLUME="$2"; shift 2 ;;
        *) die "неизвестный параметр: $1" ;;
    esac
done

[[ -f "$PKI_DIR/root_ca.crt" ]] || die "нет $PKI_DIR/root_ca.crt: сначала scripts/pki/init.sh"
[[ "$(docker inspect -f '{{.State.Running}}' "$PKI_CA_CONTAINER" 2>/dev/null)" == "true" ]] \
    || die "контейнер $PKI_CA_CONTAINER не запущен (docker compose --profile pki up -d step-ca)"
NETWORK="$(docker inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$PKI_CA_CONTAINER" | head -1)"

info "токен для $NAME (имена: ${SANS[*]})"
TOKEN_ARGS=()
for san in "${SANS[@]}"; do TOKEN_ARGS+=(--san "$san"); done
TOKEN="$(docker exec "$PKI_CA_CONTAINER" step ca token "$NAME" "${TOKEN_ARGS[@]}" \
    --issuer "$PKI_PROVISIONER" \
    --key /home/step/secrets/provisioner_key.json \
    --password-file /home/step/secrets/provisioner_password \
    --ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt)"
[[ -n "$TOKEN" ]] || die "не удалось получить токен"

info "сертификат в том $VOLUME"
docker volume create "$VOLUME" >/dev/null
printf '%s\n' "$TOKEN" | docker run --rm -i --entrypoint "" --user 0 --network "$NETWORK" \
    -e STEPPATH=/tmp/step -e OWNER="$OWNER_UID:$OWNER_GID" \
    -v "$VOLUME:/certs" -v "$PKI_DIR/root_ca.crt:/root_ca.crt:ro" "$STEP_IMAGE" sh -ec '
        read -r TOKEN
        step ca certificate "'"$NAME"'" /certs/tls.crt /certs/tls.key --token "$TOKEN" \
            --ca-url "https://'"$PKI_CA_HOST"':9000" --root /root_ca.crt --force
        cp /root_ca.crt /certs/root_ca.crt
        chown "$OWNER" /certs /certs/tls.crt /certs/tls.key /certs/root_ca.crt
        chmod 0755 /certs; chmod 0644 /certs/tls.crt /certs/root_ca.crt; chmod 0600 /certs/tls.key
        step certificate inspect /certs/tls.crt --short
    '
cat <<EOM

Готово. Том $VOLUME: tls.crt, tls.key, root_ca.crt.
Чтобы сертификат не истёк, рядом с сервисом должен работать обновляющий контейнер
(infra/pki/renewer.sh): см. infra/pki/README.md.
EOM
