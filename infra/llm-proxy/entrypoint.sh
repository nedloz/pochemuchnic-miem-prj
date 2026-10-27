#!/bin/sh
# Точка входа llm-proxy: подготовка и передача управления штатной точке входа образа nginx
# (/docker-entrypoint.sh — она отрисовывает шаблоны и запускает nginx PID 1, чтобы SIGHUP от
# llm-proxy-certs в режиме mTLS доходил до него).
#
# 1. Если на томе llm_proxy_config ещё нет config.json, кладёт туда config.default.json. Существующий
#    файл не трогается, даже битый: его меняет оператор или админка db-svc, а прокси работает по
#    последней корректной версии.
# 2. Ограничивает envsubst переменными LLM_PROXY_*: без фильтра подставлялись бы все переменные
#    окружения, в том числе ROUTER_KEY, и ключ оказался бы в файле конфигурации.
set -eu

CONFIG_DIR=/etc/llm-proxy
if [ ! -e "$CONFIG_DIR/config.json" ]; then
    mkdir -p "$CONFIG_DIR"
    # Через временный файл и rename, как и любая другая запись в этот файл.
    cp /etc/nginx/llm-proxy/config.default.json "$CONFIG_DIR/config.json.tmp"
    chmod 0644 "$CONFIG_DIR/config.json.tmp"
    mv "$CONFIG_DIR/config.json.tmp" "$CONFIG_DIR/config.json"
    echo "llm-proxy: $CONFIG_DIR/config.json создан из config.default.json"
fi

export NGINX_ENVSUBST_TEMPLATE_DIR=/etc/nginx/llm-proxy
export NGINX_ENVSUBST_FILTER='^LLM_PROXY_'
export LLM_PROXY_LISTEN="${LLM_PROXY_LISTEN:-8080}"

exec /docker-entrypoint.sh "$@"
