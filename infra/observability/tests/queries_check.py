#!/usr/bin/env python3
"""Прогоняет все запросы дашбордов через Prometheus и Loki работающего стека проекта obs-test.

Проверяет, что PromQL и LogQL синтаксически валидны (данных может не быть: статус success).
Вызывается из stack_e2e.sh; контейнеры prometheus и loki должны быть запущены.

    python3 infra/observability/tests/queries_check.py <ip-loki>
"""

from __future__ import annotations

import json
import subprocess
import sys
import urllib.parse
from pathlib import Path

BOARDS = Path(__file__).resolve().parents[1] / "grafana/dashboards"
failures = 0


def post(url: str, data: dict[str, str]) -> dict:
    body = urllib.parse.urlencode(data)
    out = subprocess.run(
        ["docker", "exec", "prometheus", "wget", "-qO-", f"--post-data={body}", url],
        capture_output=True, text=True,
    )
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return {"status": "error", "error": (out.stderr or out.stdout)[:200]}


loki_ip = sys.argv[1] if len(sys.argv) > 1 else None
checked = 0
for path in sorted(BOARDS.glob("*.json")):
    board = json.loads(path.read_text(encoding="utf-8"))
    for panel in board["panels"]:
        for target in panel.get("targets", []):
            expr = target["expr"]
            uid = target["datasource"]["uid"]
            if uid == "prometheus":
                result = post("http://localhost:9090/api/v1/query", {"query": expr})
            elif loki_ip:
                # Переменные дашборда подставляем так, как Grafana подставила бы «все» и пустой поиск.
                expr = expr.replace("$service", ".+").replace("$search", "")
                result = post(f"http://{loki_ip}:3100/loki/api/v1/query_range", {"query": expr, "limit": "1"})
            else:
                continue
            checked += 1
            if result.get("status") != "success":
                failures += 1
                print(f"ПРОВАЛ  {path.name}, «{panel['title']}»: {result.get('error') or result}")

print(f"Проверено запросов: {checked}, провалов: {failures}")
sys.exit(1 if failures else 0)
