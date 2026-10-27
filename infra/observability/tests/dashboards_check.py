#!/usr/bin/env python3
"""Проверка дашбордов Grafana без запуска стека.

  1. JSON валиден, uid дашбордов уникальны, id панелей внутри дашборда уникальны;
  2. каждая метрика в запросах Prometheus известна: определена в services/*/app/metrics.py,
     есть в каталоге экспортёров (grafana/exporter_metrics.txt) или в стандартных HTTP-метриках;
  3. каждая бизнес-метрика pochemuchnik_* из кода сервисов используется хотя бы на одном дашборде.

    python3 infra/observability/tests/dashboards_check.py        # код возврата - число провалов
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
BOARDS = REPO / "infra/observability/grafana/dashboards"
CATALOGUE = REPO / "infra/observability/grafana/exporter_metrics.txt"

# Метрики prometheus-fastapi-instrumentator и сам сбор.
HTTP = {"up"} | {
    f"{base}{suffix}"
    for base, suffixes in {
        "http_requests_total": [""],
        "http_requests_inprogress": [""],
        "http_request_duration_seconds": ["_bucket", "_sum", "_count"],
        "http_request_duration_highr_seconds": ["_bucket", "_sum", "_count"],
        "http_request_size_bytes": ["_bucket", "_sum", "_count"],
        "http_response_size_bytes": ["_bucket", "_sum", "_count"],
    }.items()
    for suffix in suffixes
}
DEFINITION = re.compile(r'\b(Counter|Gauge|Histogram)\(\s*"(pochemuchnik_[a-z0-9_]+)"')
TOKEN = re.compile(r"\b((?:pochemuchnik|node|container|redis|pg|nginx|minio|http)_[a-zA-Z0-9_]+)")

failures = 0


def check(cond: bool, message: str) -> None:
    global failures
    if not cond:
        failures += 1
        print(f"ПРОВАЛ  {message}")


def defined_metrics() -> dict[str, set[str]]:
    """Базовое имя -> все имена рядов, которые оно порождает."""
    result: dict[str, set[str]] = {}
    for path in sorted((REPO / "services").glob("*/app/metrics.py")):
        for kind, name in DEFINITION.findall(path.read_text(encoding="utf-8")):
            result[name] = {f"{name}_bucket", f"{name}_sum", f"{name}_count"} if kind == "Histogram" else {name}
    return result


defined = defined_metrics()
check(len(defined) > 0, "в services/*/app/metrics.py не найдено ни одной бизнес-метрики")
known = set(HTTP) | {n for names in defined.values() for n in names}
known |= {line.strip() for line in CATALOGUE.read_text(encoding="utf-8").splitlines() if line.strip()}

uids: dict[str, str] = {}
used: set[str] = set()
files = sorted(BOARDS.glob("*.json"))
check(len(files) == 7, f"ожидалось 7 дашбордов, найдено {len(files)}")

for path in files:
    try:
        board = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        check(False, f"{path.name}: невалидный JSON ({exc})")
        continue
    uid = board.get("uid", "")
    check(bool(uid) and uid not in uids, f"{path.name}: uid '{uid}' пуст или повторяется в {uids.get(uid)}")
    uids[uid] = path.name
    ids = [p["id"] for p in board["panels"]]
    check(len(ids) == len(set(ids)), f"{path.name}: id панелей повторяются")
    check(any(p["type"] != "row" for p in board["panels"]), f"{path.name}: нет ни одной панели с данными")
    for panel in board["panels"]:
        for target in panel.get("targets", []):
            if (target.get("datasource") or {}).get("uid") != "prometheus":
                continue
            for token in TOKEN.findall(target["expr"]):
                used.add(token)
                check(token in known, f"{path.name}, «{panel['title']}»: неизвестная метрика {token}")

for base, series in sorted(defined.items()):
    check(bool(series & used), f"бизнес-метрика {base} не используется ни на одном дашборде")

print(f"Дашбордов: {len(files)}, бизнес-метрик: {len(defined)}, провалов: {failures}")
sys.exit(1 if failures else 0)
