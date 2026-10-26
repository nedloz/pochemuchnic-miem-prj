#!/usr/bin/env bash
# Создаёт внутренний центр сертификации проекта (step-ca): корневой и промежуточный
# сертификаты, ключ провизионера и конфигурацию. Выполняется один раз.
#
#   scripts/pki/init.sh            # создать
#   scripts/pki/init.sh --force    # удалить прежнее и создать заново (ВСЕ выданные сертификаты станут недействительны)
#
# Схема: корневой ключ создаётся здесь, подписывает промежуточный сертификат и в запущенный CA
# не попадает. В томе CA лежит только промежуточный ключ, поэтому компрометация CA не даёт
# подделывать новые промежуточные центры, а корень можно заменить, не разбирая весь проект.
# Корневой ключ и его пароль (pki/root/) после выполнения скрипта увезите с этой машины.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

if [[ -e "$PKI_DIR/root/root_ca.crt" || -e "$PKI_DIR/root_ca.crt" ]]; then
    (( FORCE )) || die "центр сертификации уже создан ($PKI_DIR). Для пересоздания: $0 --force"
    if docker ps -a --format '{{.Names}}' | grep -qx "$PKI_CA_CONTAINER"; then
        die "контейнер $PKI_CA_CONTAINER ещё существует: остановите и удалите его перед --force"
    fi
    info "удаляю прежний центр сертификации"
    rm -rf "$PKI_DIR"
    docker volume rm -f "$PKI_CA_VOLUME" >/dev/null
fi

mkdir -p "$PKI_DIR/root"
chmod 700 "$PKI_DIR" "$PKI_DIR/root"

ROOT_PASS="$(random_secret)"
INTERMEDIATE_PASS="$(random_secret)"
PROVISIONER_PASS="$(random_secret)"
umask 077
printf '%s' "$ROOT_PASS" > "$PKI_DIR/root/root_ca.password"

info "корневой сертификат (10 лет)"
step_host -v "$PKI_DIR/root:/root-ca" "$STEP_IMAGE" step certificate create \
    "Pochemuchnik Root CA" /root-ca/root_ca.crt /root-ca/root_ca.key \
    --profile root-ca --not-after 87600h --kty EC --curve P-256 \
    --password-file /root-ca/root_ca.password --force >/dev/null
cp "$PKI_DIR/root/root_ca.crt" "$PKI_DIR/root_ca.crt"

info "промежуточный сертификат и конфигурация CA (том $PKI_CA_VOLUME)"
docker volume create "$PKI_CA_VOLUME" >/dev/null
# Работает от пользователя step (uid 1000) — под ним же запускается step-ca. Пароли
# передаются через stdin, а не через аргументы и окружение: так они не видны в `ps`/inspect.
printf '%s\n%s\n%s\n' "$INTERMEDIATE_PASS" "$PROVISIONER_PASS" "$ROOT_PASS" | docker run --rm -i \
    --entrypoint "" --user 1000:1000 -v "$PKI_CA_VOLUME:/home/step" -v "$PKI_DIR/root:/root-ca:ro" \
    -e PKI_PROVISIONER="$PKI_PROVISIONER" "$STEP_IMAGE" sh -ec '
        umask 077
        read -r INTERMEDIATE_PASS; read -r PROVISIONER_PASS; read -r ROOT_PASS
        cd /home/step
        mkdir -p config certs secrets db
        printf "%s" "$INTERMEDIATE_PASS" > secrets/password
        printf "%s" "$PROVISIONER_PASS" > secrets/provisioner_password
        printf "%s" "$ROOT_PASS" > /tmp/root_pass
        cp /root-ca/root_ca.crt certs/root_ca.crt

        step certificate create "Pochemuchnik Intermediate CA" certs/intermediate_ca.crt secrets/intermediate_ca_key \
            --profile intermediate-ca --ca /root-ca/root_ca.crt --ca-key /root-ca/root_ca.key \
            --ca-password-file /tmp/root_pass --password-file secrets/password \
            --not-after 43800h --kty EC --curve P-256 --force >/dev/null
        rm -f /tmp/root_pass

        cat > config/ca.json <<JSON
{
  "root": "/home/step/certs/root_ca.crt",
  "crt": "/home/step/certs/intermediate_ca.crt",
  "key": "/home/step/secrets/intermediate_ca_key",
  "address": ":9000",
  "dnsNames": ["step-ca", "localhost"],
  "logger": { "format": "text" },
  "db": { "type": "badgerv2", "dataSource": "/home/step/db" },
  "authority": { "provisioners": [] },
  "tls": {
    "cipherSuites": [
      "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
      "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
      "TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256",
      "TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"
    ],
    "minVersion": 1.2,
    "maxVersion": 1.3,
    "renegotiation": false
  }
}
JSON
        # Провизионер JWK: в ca.json только публичная часть, а зашифрованный закрытый ключ лежит
        # рядом с паролем и нужен лишь тому, кто выпускает токены (enroll.sh). Так CA не
        # раздаёт ключ подписи токенов никому, кто его об этом попросит.
        step crypto jwk create secrets/provisioner_pub.json secrets/provisioner_key.json \
            --kty EC --curve P-256 --password-file secrets/provisioner_password --force >/dev/null
        jq --arg name "$PKI_PROVISIONER" --slurpfile pub secrets/provisioner_pub.json \
            ".authority.provisioners = [{type: \"JWK\", name: \$name, key: \$pub[0]}]" \
            config/ca.json > config/ca.json.new
        mv config/ca.json.new config/ca.json
    '

FINGERPRINT="$(step_host -v "$PKI_DIR:/pki:ro" "$STEP_IMAGE" step certificate fingerprint /pki/root_ca.crt)"
printf '%s\n' "$FINGERPRINT" > "$PKI_DIR/root_ca.fingerprint"

cat <<EOM

Центр сертификации создан.
  корневой сертификат:   $PKI_DIR/root_ca.crt   (публичный, его получают все участники)
  отпечаток корня:       $FINGERPRINT
  том CA:                $PKI_CA_VOLUME

ВАЖНО. Корневой ключ и пароль к нему лежат в $PKI_DIR/root/. Они нужны только чтобы
выпустить новый промежуточный сертификат (раз в 5 лет или при компрометации CA). Увезите
каталог root/ с этой машины (менеджер паролей, флешка) и удалите отсюда.

Дальше:
  docker compose --profile pki up -d step-ca
  scripts/pki/enroll.sh <имя-сервиса>
EOM
