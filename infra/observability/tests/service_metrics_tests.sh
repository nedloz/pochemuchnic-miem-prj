#!/usr/bin/env bash
# Запускает tests/test_metrics.py каждого HTTP-сервиса в одноразовом контейнере: ставится только
# FastAPI (версия из requirements.txt сервиса), prometheus-клиенты и pytest, а не весь сервис.
#   infra/observability/tests/service_metrics_tests.sh [сервис ...]
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SERVICES=("$@")
[[ ${#SERVICES[@]} -gt 0 ]] || SERVICES=(auth-svc chat-svc library-svc db-svc graph-rag-svc embedding-svc)

failed=0
for svc in "${SERVICES[@]}"; do
    dir="$REPO/services/$svc"
    fastapi=$(grep -iE '^fastapi(\[[a-z]+\])?[=<>]' "$dir/requirements.txt" | head -1 | sed -E 's/\[[a-z]+\]//')
    fastapi=${fastapi:-fastapi}
    # >= в закреплённой строке заменяем на == последнего, чтобы не ставить несовместимое
    [[ $fastapi == *">="* ]] && fastapi=fastapi
    prom=$(grep -E '^prometheus-(client|fastapi-instrumentator)==' "$dir/requirements.txt" | tr '\n' ' ')
    # embedding-svc: его бизнес-метрики проверяются здесь же (torch и модель подменены заглушками).
    files=tests/test_metrics.py; [[ $svc == embedding-svc ]] && files=tests
    echo "== $svc ($fastapi)"
    if docker run --rm --entrypoint "" -v "$dir:/svc:ro" -w /svc python:3.12-slim sh -c \
        "pip install -q --disable-pip-version-check '$fastapi' $prom 'httpx<0.28' pytest >/dev/null 2>&1 && python -m pytest -q -p no:cacheprovider $files 2>&1 | tail -15"; then
        :
    else
        failed=$((failed + 1))
    fi
done
exit $failed
