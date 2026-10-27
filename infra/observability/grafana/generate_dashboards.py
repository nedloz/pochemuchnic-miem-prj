#!/usr/bin/env python3
"""Генерирует дашборды Grafana в infra/observability/grafana/dashboards/*.json.

JSON дашбордов - результат работы этого скрипта: правьте его, а не файлы, и запускайте заново
    python3 infra/observability/grafana/generate_dashboards.py
Проверка (метрики существуют, ни одна бизнес-метрика не потеряна):
    python3 infra/observability/tests/dashboards_check.py
"""

from __future__ import annotations

import json
from pathlib import Path

OUT = Path(__file__).resolve().parent / "dashboards"
PROM = {"type": "prometheus", "uid": "prometheus"}
LOKI = {"type": "loki", "uid": "loki"}


class Board:
    """Панели укладываются слева направо рядами по 24 колонки."""

    def __init__(self, uid: str, title: str, description: str):
        self.uid, self.title, self.description = uid, title, description
        self.panels: list[dict] = []
        self.variables: list[dict] = []
        self._x = 0
        self._y = 0
        self._row_h = 0
        self._id = 0

    def _place(self, w: int, h: int) -> dict:
        if self._x + w > 24:
            self._y += self._row_h
            self._x, self._row_h = 0, 0
        pos = {"x": self._x, "y": self._y, "w": w, "h": h}
        self._x += w
        self._row_h = max(self._row_h, h)
        return pos

    def row(self, title: str) -> None:
        self._y += self._row_h
        self._x, self._row_h = 0, 0
        self._id += 1
        self.panels.append({"id": self._id, "type": "row", "title": title, "collapsed": False,
                            "gridPos": {"x": 0, "y": self._y, "w": 24, "h": 1}, "panels": []})
        self._y += 1

    def _panel(self, kind: str, title: str, targets: list[tuple], w: int, h: int, *, unit: str = "short",
               datasource: dict = PROM, description: str = "", options: dict | None = None,
               extra_defaults: dict | None = None) -> None:
        self._id += 1
        defaults = {"unit": unit, **(extra_defaults or {})}
        self.panels.append({
            "id": self._id, "type": kind, "title": title, "description": description,
            "datasource": datasource, "gridPos": self._place(w, h),
            "targets": [{"refId": chr(65 + i), "datasource": datasource, "expr": expr, "legendFormat": legend}
                        for i, (expr, legend) in enumerate(targets)],
            "fieldConfig": {"defaults": defaults, "overrides": []},
            "options": options or {},
        })

    def stat(self, title, expr, *, unit="short", w=4, h=4, thresholds=None, description="", legend=""):
        defaults = {}
        if thresholds:
            defaults["thresholds"] = {"mode": "absolute", "steps": thresholds}
            defaults["color"] = {"mode": "thresholds"}
        self._panel("stat", title, [(expr, legend)], w, h, unit=unit, description=description,
                    options={"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value", "graphMode": "area"},
                    extra_defaults=defaults)

    def series(self, title, targets, *, unit="short", w=12, h=8, description=""):
        self._panel("timeseries", title, targets, w, h, unit=unit, description=description,
                    options={"legend": {"displayMode": "list", "placement": "bottom"},
                             "tooltip": {"mode": "multi"}},
                    extra_defaults={"custom": {"lineWidth": 1, "fillOpacity": 8}})

    def bars(self, title, expr, legend, *, unit="short", w=12, h=8, description=""):
        self._panel("bargauge", title, [(expr, legend)], w, h, unit=unit, description=description,
                    options={"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "horizontal",
                             "displayMode": "gradient"})

    def table(self, title, expr, *, w=12, h=8, description=""):
        self._panel("table", title, [(expr, "")], w, h, description=description,
                    options={"showHeader": True})
        self.panels[-1]["targets"][0].update({"instant": True, "format": "table"})

    def logs(self, title, expr, *, w=24, h=12):
        self._panel("logs", title, [(expr, "")], w, h, datasource=LOKI,
                    options={"showTime": True, "wrapLogMessage": True, "sortOrder": "Descending",
                             "enableLogDetails": True})
        self.panels[-1]["targets"][0]["queryType"] = "range"

    def logs_volume(self, title, expr, *, w=12, h=8):
        self._panel("timeseries", title, [(expr, "{{service}}")], w, h, datasource=LOKI, unit="short",
                    options={"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
                    extra_defaults={"custom": {"lineWidth": 1, "fillOpacity": 8}})
        self.panels[-1]["targets"][0]["queryType"] = "range"

    def to_json(self) -> dict:
        return {
            "uid": self.uid, "title": self.title, "description": self.description,
            "tags": ["pochemuchnik"], "timezone": "browser", "editable": False,
            "schemaVersion": 39, "version": 1, "refresh": "30s",
            "time": {"from": "now-6h", "to": "now"},
            "templating": {"list": self.variables}, "annotations": {"list": []},
            "panels": self.panels,
        }

    def save(self, filename: str) -> None:
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / filename).write_text(json.dumps(self.to_json(), ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def hq(q: float, metric: str, by: str = "", window: str = "5m") -> str:
    group = f", {by}" if by else ""
    return f"histogram_quantile({q}, sum by (le{group}) (rate({metric}_bucket[{window}])))"


GREEN_RED = [{"color": "red", "value": None}, {"color": "green", "value": 1}]
RED_GREEN_AMBER = [{"color": "green", "value": None}, {"color": "orange", "value": 0.01}, {"color": "red", "value": 0.05}]
OK_WARN_CRIT = [{"color": "green", "value": None}, {"color": "orange", "value": 70}, {"color": "red", "value": 90}]


def overview() -> Board:
    b = Board("pochemuchnik-overview", "Обзор стека", "Какие сервисы живы, доля ошибок и задержка по сервисам.")
    b.row("Состояние")
    b.stat("Сервисы приложения доступны", 'count(up{job="services"} == 1) or vector(0)', w=5,
           thresholds=GREEN_RED, description="Число сервисов, которые отвечают на сбор метрик.")
    b.stat("Недоступно целей сбора", 'count(up == 0) or vector(0)', w=5,
           thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}])
    b.stat("Запросов в секунду", 'sum(rate(http_requests_total[5m]))', unit="reqps", w=5)
    b.stat("Доля ответов 5xx", 'sum(rate(http_requests_total{status="5xx"}[5m])) / sum(rate(http_requests_total[5m]))',
           unit="percentunit", w=5, thresholds=RED_GREEN_AMBER)
    b.stat("Запросов в обработке", 'sum(http_requests_inprogress)', w=4)
    b.row("Сервисы")
    b.table("Цели сбора: 1 доступна, 0 нет", 'up', w=12)
    b.series("Запросы в секунду по сервисам", [('sum by (service) (rate(http_requests_total[5m]))', "{{service}}")], unit="reqps")
    b.series("Доля ошибок 5xx по сервисам",
             [('sum by (service) (rate(http_requests_total{status="5xx"}[5m])) / sum by (service) (rate(http_requests_total[5m]))', "{{service}}")],
             unit="percentunit")
    b.series("Задержка запросов p95 по сервисам",
             [(hq(0.95, "http_request_duration_seconds", "service"), "{{service}}")], unit="s",
             description="WebSocket-соединения чата в эту метрику не входят, у них свои метрики на дашборде «Чат и RAG».")
    b.series("Запросы в обработке по сервисам", [('sum by (service) (http_requests_inprogress)', "{{service}}")])
    b.logs_volume("Строки с ошибками в логах по сервисам",
                  'sum by (service) (count_over_time({service=~".+"} |~ "(?i)(error|exception|traceback)" [5m]))')
    return b


def host() -> Board:
    b = Board("pochemuchnik-host", "Хост и контейнеры", "CPU, память, диск и сеть машины и контейнеров.")
    b.row("Машина")
    b.stat("CPU занято", '100 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100', unit="percent", w=6,
           thresholds=OK_WARN_CRIT)
    b.stat("Память занята", '1 - sum(node_memory_MemAvailable_bytes) / sum(node_memory_MemTotal_bytes)',
           unit="percentunit", w=6, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.8}, {"color": "red", "value": 0.92}])
    b.stat("Диск / занят", '1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}',
           unit="percentunit", w=6, thresholds=[{"color": "green", "value": None}, {"color": "orange", "value": 0.8}, {"color": "red", "value": 0.92}])
    b.stat("Нагрузка (load1)", 'node_load1', w=6)
    b.series("CPU по режимам", [('sum by (mode) (rate(node_cpu_seconds_total{mode!="idle"}[5m])) / count(count by (cpu) (node_cpu_seconds_total))', "{{mode}}")], unit="percentunit")
    b.series("Память", [('node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes', "занято"),
                        ('node_memory_MemAvailable_bytes', "доступно")], unit="bytes")
    b.series("Нагрузка", [('node_load1', "1 мин"), ('node_load5', "5 мин"), ('node_load15', "15 мин")])
    b.series("Сеть машины", [('sum(rate(node_network_receive_bytes_total{device!~"lo|veth.*|br-.*|docker.*"}[5m]))', "принято"),
                             ('sum(rate(node_network_transmit_bytes_total{device!~"lo|veth.*|br-.*|docker.*"}[5m]))', "отправлено")], unit="Bps")
    b.row("Контейнеры")
    b.series("CPU по контейнерам", [('sum by (name) (rate(container_cpu_usage_seconds_total{name!=""}[5m]))', "{{name}}")],
             unit="percentunit", w=24, h=9)
    b.series("Память по контейнерам", [('sum by (name) (container_memory_working_set_bytes{name!=""})', "{{name}}")],
             unit="bytes", w=12, h=9)
    b.series("Сеть по контейнерам (приём)", [('sum by (name) (rate(container_network_receive_bytes_total{name!=""}[5m]))', "{{name}}")],
             unit="Bps", w=12, h=9)
    b.series("Перезапуски контейнеров за час", [('changes(container_start_time_seconds{name!=""}[1h])', "{{name}}")], w=24)
    return b


def chat_rag() -> Board:
    b = Board("pochemuchnik-chat-rag", "Чат и RAG", "Соединения, сообщения, время ответа, выбор маршрута поиска, пустой контекст, оценки.")
    b.row("Чат")
    b.stat("Открытые соединения", 'sum(pochemuchnik_ws_connections_active)', w=6)
    b.stat("Соединений за час", 'sum(increase(pochemuchnik_ws_connections_total[1h]))', w=6)
    b.stat("Сбоев генерации за час", 'sum(increase(pochemuchnik_generation_failures_total[1h])) or vector(0)', w=6,
           thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}])
    b.stat("Ошибок LLM за час", 'sum(increase(pochemuchnik_llm_errors_total[1h])) or vector(0)', w=6,
           thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}])
    b.series("Сообщения в минуту по ролям", [('sum by (role) (rate(pochemuchnik_messages_total[5m])) * 60', "{{role}}")])
    b.series("Время до первого фрагмента ответа",
             [(hq(0.5, "pochemuchnik_time_to_first_token_seconds", window="15m"), "p50"),
              (hq(0.95, "pochemuchnik_time_to_first_token_seconds", window="15m"), "p95")], unit="s")
    b.series("Полное время ответа p95 по исходу",
             [(hq(0.95, "pochemuchnik_answer_duration_seconds", "outcome", "15m"), "{{outcome}}")], unit="s")
    b.series("Сбои генерации за час по причине",
             [('sum by (reason) (increase(pochemuchnik_generation_failures_total[1h]))', "{{reason}}")])
    b.bars("Оценки ответов за сутки", 'sum by (value) (increase(pochemuchnik_feedback_total[24h]))', "{{value}}")
    b.series("Попадания в кэш Redis",
             [('sum by (kind) (rate(pochemuchnik_redis_cache_requests_total{outcome="hit"}[15m])) / sum by (kind) (rate(pochemuchnik_redis_cache_requests_total[15m]))', "{{kind}}")],
             unit="percentunit")
    b.row("Поиск и генерация (graph-rag-svc)")
    b.series("Запросы /generate в минуту по режиму", [('sum by (mode) (rate(pochemuchnik_generate_requests_total[5m])) * 60', "{{mode}}")])
    b.series("Маршрут поиска (judge) в минуту",
             [('sum by (route) (rate(pochemuchnik_judge_decisions_total[5m])) * 60', "{{route}}")],
             description="graph_to_vector: граф ничего не нашёл, сработал откат на вектор.")
    b.series("Длительность этапов p95",
             [(hq(0.95, "pochemuchnik_stage_duration_seconds", "stage", "15m"), "{{stage}}")], unit="s")
    b.series("Чанков в контексте (среднее)",
             [('sum(rate(pochemuchnik_context_chunks_sum[15m])) / sum(rate(pochemuchnik_context_chunks_count[15m]))', "чанков")])
    b.series("Доля ответов с пустым контекстом",
             [('sum(rate(pochemuchnik_empty_context_total[15m])) / sum(rate(pochemuchnik_context_chunks_count[15m]))', "пустой контекст")],
             unit="percentunit")
    b.series("Сбои поиска и ошибки LLM за час",
             [('sum(increase(pochemuchnik_retrieval_failures_total[1h]))', "сбои поиска"),
              ('sum(increase(pochemuchnik_llm_errors_total[1h]))', "ошибки LLM")])
    return b


def documents() -> Board:
    b = Board("pochemuchnik-documents", "Документы и ingest", "Очередь индексации, чанки, эмбеддинги, предпросмотр и его кэш.")
    b.row("Библиотека")
    b.stat("Опубликовано документов", 'pochemuchnik_documents{status="published"}', w=6)
    b.stat("Черновиков", 'pochemuchnik_documents{status="draft"}', w=6)
    b.stat("Чанков в корпусе", 'pochemuchnik_corpus_objects{kind="chunks"}', w=6)
    b.stat("Узлов графа", 'pochemuchnik_corpus_objects{kind="graph_nodes"}', w=6)
    b.series("Размер корпуса и графа", [('pochemuchnik_corpus_objects', "{{kind}}")], w=12)
    b.series("Документы по статусу публикации", [('pochemuchnik_documents', "{{status}}")], w=12)
    b.row("Индексация (ingest-worker)")
    b.series("Очередь индексации", [('pochemuchnik_ingest_queue_depth', "{{status}}")])
    b.series("Документы в минуту по результату", [('sum by (result) (rate(pochemuchnik_ingest_jobs_total[5m])) * 60', "{{result}}")])
    b.series("Длительность обработки документа p95",
             [(hq(0.95, "pochemuchnik_ingest_job_duration_seconds", "result", "30m"), "{{result}}")], unit="s")
    b.series("Чанков создаётся в минуту", [('sum(rate(pochemuchnik_ingest_chunks_created_total[5m])) * 60', "чанков")])
    b.series("Ошибки обработки за час по типу", [('sum by (type) (increase(pochemuchnik_ingest_job_errors_total[1h]))', "{{type}}")], w=24)
    b.row("Эмбеддинги (embedding-svc)")
    b.series("Запросы /embed в минуту", [('sum(rate(pochemuchnik_embed_requests_total[5m])) * 60', "запросов")])
    b.series("Размер пакета (среднее)",
             [('sum(rate(pochemuchnik_embed_batch_size_sum[15m])) / sum(rate(pochemuchnik_embed_batch_size_count[15m]))', "текстов")])
    b.series("Время кодирования p95", [(hq(0.95, "pochemuchnik_embed_duration_seconds", window="15m"), "p95")], unit="s", w=24)
    b.row("Предпросмотр и скачивание")
    b.series("Предпросмотры в минуту по режиму", [('sum by (mode) (rate(pochemuchnik_preview_requests_total[5m])) * 60', "{{mode}}")])
    b.series("Попадания в кэш конвертации",
             [('sum(rate(pochemuchnik_preview_cache_requests_total{outcome="hit"}[15m])) / sum(rate(pochemuchnik_preview_cache_requests_total{outcome=~"hit|miss"}[15m]))', "доля попаданий")],
             unit="percentunit")
    b.series("Конвертация LibreOffice p95", [(hq(0.95, "pochemuchnik_preview_convert_duration_seconds", window="30m"), "p95")], unit="s")
    b.series("Вытеснения из кэша и скачивания в минуту",
             [('sum(rate(pochemuchnik_preview_cache_evictions_total[5m])) * 60', "вытеснения"),
              ('sum(rate(pochemuchnik_downloads_total[5m])) * 60', "скачивания")])
    return b


def users() -> Board:
    b = Board("pochemuchnik-users", "Пользователи и админка", "Регистрации, входы, письма и действия администраторов.")
    b.row("Пользователи")
    b.stat("Регистраций за сутки", 'sum(increase(pochemuchnik_registrations_total[24h]))', w=6)
    b.stat("Успешных входов за сутки", 'sum(increase(pochemuchnik_logins_total{result="success"}[24h]))', w=6)
    b.stat("Писем отправлено за сутки", 'sum(increase(pochemuchnik_emails_sent_total{result="sent"}[24h]))', w=6)
    b.stat("Писем не отправлено за сутки", 'sum(increase(pochemuchnik_emails_sent_total{result="failed"}[24h])) or vector(0)', w=6,
           thresholds=[{"color": "green", "value": None}, {"color": "red", "value": 1}])
    b.series("Входы в час по результату", [('sum by (result) (increase(pochemuchnik_logins_total[1h]))', "{{result}}")])
    b.series("Обновления токена в час по результату", [('sum by (result) (increase(pochemuchnik_token_refresh_total[1h]))', "{{result}}")])
    b.series("Письма в час по виду и результату",
             [('sum by (kind, result) (increase(pochemuchnik_emails_sent_total[1h]))', "{{kind}} / {{result}}")])
    b.series("Регистрации в час", [('sum(increase(pochemuchnik_registrations_total[1h]))', "регистрации")])
    b.row("Администраторы")
    b.series("Админ-сессии в час", [('sum(increase(pochemuchnik_admin_sessions_total[1h]))', "сессии")])
    b.series("Действия администраторов в час",
             [('sum by (action, result) (increase(pochemuchnik_admin_actions_total[1h]))', "{{action}} / {{result}}")])
    b.series("Импорты за сутки", [('sum by (kind, result) (increase(pochemuchnik_imports_total[24h]))', "{{kind}} / {{result}}")], w=24)
    return b


def storage() -> Board:
    b = Board("pochemuchnik-storage", "Хранилища", "Postgres, Redis, MinIO и шлюз nginx.")
    b.row("Состояние")
    b.stat("Postgres", 'pg_up', w=6, thresholds=GREEN_RED)
    b.stat("Redis", 'redis_up', w=6, thresholds=GREEN_RED)
    b.stat("MinIO (1 здоров)", 'minio_cluster_health_status', w=6, thresholds=GREEN_RED)
    b.stat("nginx", 'nginx_up', w=6, thresholds=GREEN_RED)
    b.row("Postgres")
    b.series("Соединения по базам", [('pg_stat_database_numbackends{datname!~"template.*"}', "{{datname}}")])
    b.series("Размер баз", [('pg_database_size_bytes{datname!~"template.*"}', "{{datname}}")], unit="bytes")
    b.series("Транзакции в секунду", [('sum(rate(pg_stat_database_xact_commit[5m]))', "commit"),
                                       ('sum(rate(pg_stat_database_xact_rollback[5m]))', "rollback")], unit="ops")
    b.series("Попадания в кэш буферов",
             [('sum(rate(pg_stat_database_blks_hit[5m])) / (sum(rate(pg_stat_database_blks_hit[5m])) + sum(rate(pg_stat_database_blks_read[5m])))', "доля попаданий")],
             unit="percentunit")
    b.series("Взаимные блокировки", [('sum(increase(pg_stat_database_deadlocks[1h]))', "за час")])
    b.row("Redis")
    b.series("Память Redis", [('redis_memory_used_bytes', "используется")], unit="bytes")
    b.series("Клиенты и команды", [('redis_connected_clients', "клиенты"),
                                    ('rate(redis_commands_processed_total[5m])', "команд/с")])
    b.series("Попадания и промахи по ключам", [('rate(redis_keyspace_hits_total[5m])', "попадания"),
                                                ('rate(redis_keyspace_misses_total[5m])', "промахи")], unit="ops")
    b.series("Вытеснение ключей", [('rate(redis_evicted_keys_total[5m])', "вытеснено/с")], unit="ops")
    b.row("MinIO")
    b.series("Место в MinIO", [('minio_cluster_capacity_usable_total_bytes - minio_cluster_capacity_usable_free_bytes', "занято"),
                               ('minio_cluster_capacity_usable_free_bytes', "свободно")], unit="bytes")
    b.series("S3-запросы и трафик", [('rate(minio_s3_requests_incoming_total[5m])', "запросов/с"),
                                      ('rate(minio_s3_traffic_received_bytes[5m])', "принято, Б/с")])
    b.series("Процесс MinIO", [('minio_node_process_resident_memory_bytes', "память")], unit="bytes")
    b.row("nginx")
    b.series("Запросы и соединения", [('rate(nginx_http_requests_total[5m])', "запросов/с"),
                                       ('nginx_connections_active', "активных соединений")])
    return b


def logs() -> Board:
    b = Board("pochemuchnik-logs", "Логи", "Поиск по логам всех контейнеров и ошибки по сервисам (источник Loki).")
    b.variables = [
        {"name": "service", "label": "Сервис", "type": "query", "datasource": LOKI,
         "query": {"label": "service", "refId": "LokiVariableQuery", "stream": "", "type": 1},
         "refresh": 2, "includeAll": True, "multi": True, "allValue": ".+", "current": {"text": "All", "value": "$__all"}},
        {"name": "search", "label": "Текст", "type": "textbox", "query": "", "current": {"text": "", "value": ""}},
    ]
    b.row("Ошибки")
    b.logs_volume("Строки с ошибками по сервисам",
                  'sum by (service) (count_over_time({service=~"$service"} |~ "(?i)(error|exception|traceback)" [5m]))', w=24)
    b.row("Поиск")
    b.logs("Логи выбранных сервисов", '{service=~"$service"} |~ "(?i)$search"', h=16)
    b.logs("Только ошибки", '{service=~"$service"} |~ "(?i)(error|exception|traceback)"', h=12)
    return b


def main() -> None:
    boards = {
        "overview.json": overview(), "host.json": host(), "chat-rag.json": chat_rag(),
        "documents-ingest.json": documents(), "auth.json": users(), "storage.json": storage(), "logs.json": logs(),
    }
    for filename, board in boards.items():
        board.save(filename)
    print(f"{len(boards)} дашбордов записано в {OUT}")


if __name__ == "__main__":
    main()
