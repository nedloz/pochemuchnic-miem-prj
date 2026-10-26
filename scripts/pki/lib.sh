# Общие настройки скриптов scripts/pki/*. Подключается через `source`, сам ничего не делает.
#
# Всё переопределяется переменными окружения; это нужно в первую очередь самопроверке
# (infra/pki/tests/selftest.sh), которая поднимает отдельный CA, не трогая настоящий.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Образ закреплён: формат конфигурации и поведение CLI меняются между версиями.
STEP_IMAGE="${STEP_IMAGE:-smallstep/step-ca:0.30.2}"

# Корневой сертификат и его ключ. Каталог в .gitignore. Ключ корня нужен только при выпуске
# промежуточного сертификата (init.sh), после чего его место не в этом каталоге, а в офлайне.
PKI_DIR="${PKI_DIR:-$REPO_ROOT/pki}"

# Контейнер CA (container_name в docker-compose.yml) и том с его состоянием. Имя тома по
# умолчанию такое же, как у остальных томов проекта: <каталог>_step_ca_data.
PKI_CA_CONTAINER="${PKI_CA_CONTAINER:-step-ca}"
PKI_CA_VOLUME="${PKI_CA_VOLUME:-$(basename "$REPO_ROOT" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9_-')_step_ca_data}"

# Имя CA в сети: оно записано в его серверный сертификат (dnsNames в ca.json), поэтому клиенты
# обязаны обращаться именно так. В compose это сервис и container_name step-ca.
PKI_CA_HOST="${PKI_CA_HOST:-step-ca}"

# Имя провизионера, через который выдаются сертификаты сервисам.
PKI_PROVISIONER="${PKI_PROVISIONER:-bootstrap}"

die() { echo "ОШИБКА: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# Выполнить команду step в одноразовом контейнере от имени текущего пользователя хоста,
# чтобы создаваемые файлы принадлежали ему, а не root.
step_host() {
    docker run --rm --entrypoint "" --user "$(id -u):$(id -g)" -e STEPPATH=/tmp/step "$@"
}

random_secret() { head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | head -c 40; }
