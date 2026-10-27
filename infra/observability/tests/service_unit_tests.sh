#!/usr/bin/env bash
# Запускает тесты сервиса в одноразовом контейнере с зависимостями из его requirements.txt.
# Для проверок, которым нужен код сервиса (бизнес-метрики); лёгкая проверка HTTP-метрик —
# service_metrics_tests.sh. Основной стек не затрагивается.
#   infra/observability/tests/service_unit_tests.sh <сервис> [файл_теста ...]
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
svc=${1:?использование: $0 <сервис> [файл_теста ...]}; shift
tests=("$@"); [[ ${#tests[@]} -gt 0 ]] || tests=(tests)
docker run --rm --entrypoint "" -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$REPO/services/$svc:/svc:ro" -w /svc python:3.12-slim sh -c \
    "pip install -q --disable-pip-version-check -r requirements.txt pytest >/dev/null 2>&1 \
     && { pip show httpx >/dev/null 2>&1 || pip install -q --disable-pip-version-check 'httpx<0.28' >/dev/null 2>&1; } \
     && python -m pytest -q -p no:cacheprovider ${tests[*]} 2>&1 | tail -25"
