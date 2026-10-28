"""Сквозная проверка пайплайна ноутбука на одноразовых контейнерах.

Поднимает в отдельной сети docker:
- pgvector/pgvector:pg16 с infra/db/init и всеми миграциями infra/db/migrations;
- заглушку embedding-svc (tests/notebook_flow/embedding_stub.py, векторы flow_vectors.embed);
- заглушку upstream LLM (tests/notebook_flow/llm_stub.py) за НАСТОЯЩИМ llm-proxy (nginx:1.27-alpine
  с infra/llm-proxy, как в docker-compose.yml, режим router);
- НАСТОЯЩИЙ graph-rag-svc, собранный из services/graph-rag-svc (INTERNAL_AUTH_MODE=insecure,
  без chat-svc: вопросы идут в response_mode="sync").
В базу кладутся два проиндексированных документа по три чанка, быстрые ответы с вариантами и
ссылки; векторы считаются той же функцией, что и в заглушке embedding-svc.

Проверки (по строке PASS/FAIL на каждую):
  (a) вопрос, равный варианту быстрого ответа, — готовый ответ, route_used=quick_answer, LLM не вызывалась;
  (b) вопрос по документу — ответ через llm-proxy с источником, route_used=hybrid; заглушка видела
      переписывание, реранк и ответ с моделью роутера из config.json и ключом прокси, а не клиента;
  (c) вопросы уходят в embedding-svc с kind=query;
  (d) вопрос не по теме проходит через промпт с guardrails;
  (f) вопрос в 20000 символов принимается и доходит до LLM обрезанным до 4000;
  (e) upstream LLM недоступен — /generate отвечает 502 за секунды, а не висит.
Основной стек docker compose, настоящие embedding-svc и роутер не используются. Всё созданное
(контейнеры, сеть, том, образ, если его не было до запуска) удаляется в finally.

  python tests/test_notebook_pipeline_flow.py          # код возврата 0 — всё прошло
  KEEP_IMAGE=1 python tests/test_notebook_pipeline_flow.py   # не удалять собранный образ
"""

import json
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FLOW_DIR = ROOT / "tests" / "notebook_flow"
sys.path.insert(0, str(FLOW_DIR))
import flow_vectors  # noqa: E402

P = f"nbflow{os.getpid()}"
NET = f"{P}-net"
DB = f"{P}-db"
EMB = f"{P}-emb"
LLM_UP = f"{P}-llmup"
PROXY = f"{P}-proxy"
GRS = f"{P}-grs"
PROXY_VOLUME = f"{P}-proxycfg"
IMAGE = os.getenv("NBFLOW_IMAGE", "nbflow/graph-rag-svc:test")
KEEP_IMAGE = os.getenv("KEEP_IMAGE", "").lower() in {"1", "true", "yes"}

ROUTER_KEY = "sk-flow-" + os.urandom(8).hex()
ROUTER_MODEL = "stub-router-model"
PROXY_CONFIG = {
    "mode": "router",
    "router": {"url": "http://llm-upstream:9000/v1", "model": ROUTER_MODEL},
    "ollama": {"url": "http://llm-upstream:9000/v1", "model": "stub-ollama-model"},
}
GUARDRAIL_MARKERS = (
    "СТРОГИЕ ПРАВИЛА ОГРАНИЧЕНИЯ ТЕМ (Guardrails)",
    "Я помогаю только с вопросами, связанными с учебой и правилами в НИУ ВШЭ",
)
MAX_QUESTION_CHARS = 4000

# --- данные --------------------------------------------------------------------------------

DOCS = [
    {
        "id": "00000000-0000-0000-0000-00000000d001",
        "title": "Положение о стипендиях",
        "category": "Учебный процесс",
        "chunks": [
            ("1. Академическая стипендия",
             "Академическая стипендия назначается студентам, сдавшим сессию на хорошо и отлично, "
             "приказом декана на один семестр."),
            ("2. Повышенная стипендия",
             "Повышенная стипендия назначается за достижения в учебной, научной и общественной "
             "деятельности по решению стипендиальной комиссии."),
            ("3. Выплата",
             "Выплата стипендии производится ежемесячно до двадцать пятого числа на банковскую "
             "карту студента."),
        ],
    },
    {
        "id": "00000000-0000-0000-0000-00000000d002",
        "title": "Правила проживания в общежитии",
        "category": "Общие документы",
        "chunks": [
            ("1. Заселение",
             "Заселение в общежитие проводится по направлению управления по работе со студентами "
             "при наличии свободных мест."),
            ("2. Оплата",
             "Плата за проживание вносится ежемесячно через личный кабинет до десятого числа."),
            ("3. Гости",
             "Гости могут находиться в общежитии с восьми до двадцати трёх часов при предъявлении "
             "документа."),
        ],
    },
]

# (основной вопрос, ответ, варианты). Вариантов много нарочно: на крошечном корпусе BM25 (rank_bm25)
# может обнулить оценки, и быстрый путь не сработал бы по причинам, не связанным с проверкой.
QUICK_ANSWERS = [
    ("Где получить студенческий билет?",
     "Студенческий билет выдаёт учебный офис образовательной программы.",
     ["Где взять студбилет?", "Как получить студенческий?", "Кто выдаёт студенческий билет?"]),
    ("Как оформить пропуск в корпус?",
     "Пропуск оформляется в личном кабинете, забрать его можно на посту охраны.",
     ["Где сделать пропуск?", "Пропуск в здание как получить", "Потерял пропуск, что делать?"]),
    ("Когда работает библиотека?",
     "Библиотека открыта по будням с 9:00 до 21:00.",
     ["Часы работы библиотеки", "До скольки открыта библиотека?"]),
    ("Как подключиться к Wi-Fi?",
     "Сеть eduroam: логин и пароль от корпоративной учётной записи.",
     ["Пароль от вайфай", "Какая сеть wifi в корпусе?"]),
    ("Как получить справку об обучении?",
     "Справку об обучении заказывают в личном кабинете, готовность — три рабочих дня.",
     ["Где заказать справку с места учебы?", "Справка для военкомата"]),
    ("Где посмотреть расписание занятий?",
     "Расписание публикуется в приложении и на сайте РУЗ.",
     ["Расписание пар", "Как узнать расписание?"]),
    ("Как оформить медицинский полис?",
     "Полис ДМС оформляет управление по работе со студентами.",
     ["Где получить полис ДМС?", "Медицинская страховка студента"]),
]
QUICK_QUESTION = "Где взять студбилет?"
QUICK_EXPECTED = QUICK_ANSWERS[0][1]

LINKS = [
    ("Академическая стипендия: как назначается студентам", "http://stipend.example.test/polozhenie"),
    ("Общежития: правила заселения", "https://dorm.example.test/rules"),
    ("Расписание занятий РУЗ", "https://ruz.example.test/"),
]
HTTP_LINK = LINKS[0][1]

DOC_QUESTION = "Как назначается академическая стипендия студентам?"
DOC_TITLE = DOCS[0]["title"]
OFFTOPIC_QUESTION = "Объясни второй закон Ньютона"


def normalize_variant(text: str) -> str:
    """Контракт нормализации вариантов (db-svc импорт, ingest-worker, graph-rag-svc)."""
    return re.sub(r"[^a-zA-Zа-яА-Я0-9\s]", "", text).lower().strip()


def embedding_text(title: str, category: str, section: str, text: str) -> str:
    """Как ingest-worker (app/notebook_chunker.py) готовит текст чанка для эмбеддинга."""
    return f"Название документа: {title}\nКатегория: {category}\nРаздел: {section}\nТекст: {text}"


def sql_str(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def vec(text: str) -> str:
    return sql_str(flow_vectors.literal(flow_vectors.embed(text))) + "::vector"


def seed_sql() -> str:
    model = sql_str(flow_vectors.MODEL)
    lines = ["BEGIN;"]
    for doc in DOCS:
        lines.append(
            "INSERT INTO library.documents (id, title, category, source_type, content_type, status, "
            "ingest_status, indexed_at) VALUES "
            f"({sql_str(doc['id'])}, {sql_str(doc['title'])}, {sql_str(doc['category'])}, 'upload', "
            "'text/plain', 'published', 'indexed', now());"
        )
        for idx, (section, text) in enumerate(doc["chunks"]):
            chunk_id = doc["id"][:-4] + f"c{doc['id'][-2:]}{idx}"
            lines.append(
                "INSERT INTO library.chunks (id, document_id, chunk_index, section_path, text) VALUES "
                f"({sql_str(chunk_id)}, {sql_str(doc['id'])}, {idx}, {sql_str(section)}, {sql_str(text)});"
            )
            lines.append(
                "INSERT INTO library.chunk_embeddings (chunk_id, embedding, embedding_model) VALUES "
                f"({sql_str(chunk_id)}, {vec(embedding_text(doc['title'], doc['category'], section, text))}, {model});"
            )
    for pos, (question, answer, variants) in enumerate(QUICK_ANSWERS):
        qa_id = f"00000000-0000-0000-0000-0000000a{pos:04d}"
        lines.append(
            "INSERT INTO library.quick_answers (id, question, answer, source) VALUES "
            f"({sql_str(qa_id)}, {sql_str(question)}, {sql_str(answer)}, 'flow-test');"
        )
        texts = list(dict.fromkeys(normalize_variant(t) for t in [question, *variants]))
        for text in texts:
            lines.append(
                "INSERT INTO library.quick_answer_variants (quick_answer_id, text, embedding, embedding_model) "
                f"VALUES ({sql_str(qa_id)}, {sql_str(text)}, {vec(text)}, {model});"
            )
    for description, url in LINKS:
        lines.append(
            "INSERT INTO library.links (description, url, embedding, embedding_model) VALUES "
            f"({sql_str(description)}, {sql_str(url)}, {vec(description)}, {model});"
        )
    lines.append("COMMIT;")
    return "\n".join(lines) + "\n"


# --- docker --------------------------------------------------------------------------------

def sh(*args: str, input_text: str | None = None, check: bool = True, timeout: float = 600) -> str:
    proc = subprocess.run(
        list(args), input=input_text, capture_output=True, text=True, timeout=timeout
    )
    if check and proc.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:4])}…: код {proc.returncode}\n{proc.stdout[-2000:]}{proc.stderr[-2000:]}")
    return proc.stdout


def docker(*args: str, **kwargs) -> str:
    return sh("docker", *args, **kwargs)


def psql(sql: str) -> str:
    return docker(
        "exec", "-i", "-e", "PGOPTIONS=-c client_min_messages=warning", DB,
        "psql", "-U", "postgres", "-d", "app_db", "-v", "ON_ERROR_STOP=1", "-q", "-At", "-f", "-",
        input_text=sql,
    )


def wait_for(description: str, probe, timeout: float, interval: float = 1.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if probe():
                return
        except Exception:
            pass
        time.sleep(interval)
    raise RuntimeError(f"не дождались: {description}")


def image_exists(name: str) -> bool:
    return subprocess.run(["docker", "image", "inspect", name], capture_output=True).returncode == 0


def jsonl(container: str, path: str) -> list[dict]:
    out = docker("exec", container, "sh", "-c", f"cat {path} 2>/dev/null || true")
    return [json.loads(line) for line in out.splitlines() if line.strip()]


# --- стенд ---------------------------------------------------------------------------------

def start_database() -> None:
    docker(
        "run", "-d", "--name", DB, "--network", NET, "--network-alias", "postgres",
        "-e", "POSTGRES_PASSWORD=test", "-e", "POSTGRES_DB=app_db",
        "-e", "AUTH_DB_PASSWORD=t", "-e", "CHAT_DB_PASSWORD=t", "-e", "LIBRARY_DB_PASSWORD=t",
        "-e", "INGEST_DB_PASSWORD=t", "-e", "GRAPH_DB_PASSWORD=t", "-e", "DBSVC_DB_PASSWORD=t",
        "-v", f"{ROOT / 'infra/db/init'}:/docker-entrypoint-initdb.d:ro",
        "pgvector/pgvector:pg16",
    )
    # Entrypoint поднимает сервер для init на сокете и перезапускает его: ждём второй запуск.
    wait_for(
        "инициализация Postgres",
        lambda: "PostgreSQL init process complete" in logs_tail(DB, 200),
        timeout=120,
    )
    wait_for(
        "pg_isready",
        lambda: subprocess.run(
            ["docker", "exec", DB, "pg_isready", "-U", "postgres", "-h", "127.0.0.1"], capture_output=True
        ).returncode == 0,
        timeout=60,
    )
    for migration in sorted((ROOT / "infra/db/migrations").glob("0*.sql")):
        psql(migration.read_text(encoding="utf-8"))
    psql(seed_sql())


def start_stubs() -> None:
    mount = f"{FLOW_DIR}:/t:ro"
    docker("run", "-d", "--name", EMB, "--network", NET, "--network-alias", "embedding-svc",
           "-v", mount, "python:3.12-slim", "python", "-u", "/t/embedding_stub.py")
    docker("run", "-d", "--name", LLM_UP, "--network", NET, "--network-alias", "llm-upstream",
           "-v", mount, "python:3.12-slim", "python", "-u", "/t/llm_stub.py")


def start_proxy() -> None:
    for name in ("nginx.conf", "default.conf.template", "llm.js", "locations.conf", "entrypoint.sh"):
        if not (ROOT / "infra/llm-proxy" / name).is_file():
            raise RuntimeError(f"нет infra/llm-proxy/{name}")
    docker("volume", "create", PROXY_VOLUME)
    # config.json кладётся до старта: в режиме по умолчанию прокси указывает на настоящий роутер.
    docker("run", "--rm", "-i", "-v", f"{PROXY_VOLUME}:/cfg", "--entrypoint", "sh", "nginx:1.27-alpine",
           "-c", "cat > /cfg/config.json.tmp && mv /cfg/config.json.tmp /cfg/config.json",
           input_text=json.dumps(PROXY_CONFIG))
    # Тот же образ, точка входа и монтирования, что у сервиса llm-proxy в docker-compose.yml.
    docker(
        "run", "-d", "--name", PROXY, "--network", NET, "--network-alias", "llm-proxy",
        "-e", f"ROUTER_KEY={ROUTER_KEY}", "-e", "LLM_PROXY_LISTEN=8080",
        "-v", f"{ROOT / 'infra/llm-proxy'}:/etc/nginx/llm-proxy:ro",
        "-v", f"{ROOT / 'infra/llm-proxy/nginx.conf'}:/etc/nginx/nginx.conf:ro",
        "-v", f"{PROXY_VOLUME}:/etc/llm-proxy",
        "--entrypoint", "/bin/sh", "nginx:1.27-alpine",
        "/etc/nginx/llm-proxy/entrypoint.sh", "nginx", "-g", "daemon off;",
    )
    wait_for(
        "llm-proxy /healthz",
        lambda: subprocess.run(
            ["docker", "exec", PROXY, "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"],
            capture_output=True,
        ).returncode == 0,
        timeout=30,
        interval=0.5,
    )


def start_graph_rag() -> str:
    docker(
        "run", "-d", "--name", GRS, "--network", NET, "-p", "127.0.0.1::8000",
        "-e", "INTERNAL_AUTH_MODE=insecure",
        "-e", "DATABASE_URL=postgresql+asyncpg://graph_user:t@postgres:5432/app_db",
        "-e", "EMBEDDING_SVC_URL=http://embedding-svc:8000",
        "-e", f"EMBEDDING_DIM={flow_vectors.DIM}",
        "-e", "EMBEDDING_STARTUP_RETRIES=10", "-e", "EMBEDDING_STARTUP_RETRY_WAIT_SEC=1",
        "-e", "LLM_BASE_URL=http://llm-proxy:8080/v1",
        # chat-svc нет: мост только пишет предупреждения, ответы идут в sync-режиме.
        "-e", "CHAT_WS_URL=ws://chat-svc:8000/ws/internal/llm", "-e", "BRIDGE_STARTUP_WAIT_SEC=1",
        IMAGE,
    )
    port = docker("port", GRS, "8000/tcp").splitlines()[0].rsplit(":", 1)[1].strip()
    base = f"http://127.0.0.1:{port}"

    def ready() -> bool:
        state = docker("inspect", "-f", "{{.State.Running}}", GRS).strip()
        if state != "true":
            raise SystemExit(f"graph-rag-svc завершился:\n{logs_tail(GRS)}")
        with urllib.request.urlopen(f"{base}/healthz", timeout=2) as resp:
            return resp.status == 200

    try:
        wait_for("graph-rag-svc /healthz", ready, timeout=120)
    except RuntimeError:
        print(logs_tail(GRS))
        raise
    return base


def logs_tail(container: str, lines: int = 40) -> str:
    proc = subprocess.run(["docker", "logs", "--tail", str(lines), container], capture_output=True, text=True)
    return proc.stdout + proc.stderr


def generate(base: str, question: str, history: list[dict] | None = None, timeout: float = 120):
    body = json.dumps({"question": question, "response_mode": "sync", "history": history or []}).encode()
    request = urllib.request.Request(
        f"{base}/generate", data=body, method="POST",
        headers={"Content-Type": "application/json", "X-Service-Name": "notebook-flow-test"},
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read()), time.monotonic() - started
    except urllib.error.HTTPError as exc:
        payload = exc.read()
        try:
            data = json.loads(payload)
        except ValueError:
            data = {"raw": payload.decode(errors="replace")}
        return exc.code, data, time.monotonic() - started


# --- проверки ------------------------------------------------------------------------------

class Results:
    def __init__(self) -> None:
        self.passed = 0
        self.failed = 0

    def check(self, name: str, ok: bool, detail: str = "") -> None:
        if ok:
            self.passed += 1
            print(f"PASS  {name}")
        else:
            self.failed += 1
            print(f"FAIL  {name}" + (f": {detail}" if detail else ""))


def question_in(text: str, before: str, after: str) -> str:
    match = re.search(re.escape(before) + r"(.*?)" + re.escape(after), text, re.S)
    return match.group(1) if match else ""


def run_checks(base: str, r: Results) -> None:
    with urllib.request.urlopen(f"{base}/ping", timeout=5) as resp:
        ping = json.loads(resp.read())
    r.check("/ping: llm_base_url = http://llm-proxy:8080/v1", ping.get("llm_base_url") == "http://llm-proxy:8080/v1",
            str(ping))

    # (a) быстрый ответ
    llm_before = len(jsonl(LLM_UP, "/tmp/llm_requests.jsonl"))
    status, data, _ = generate(base, QUICK_QUESTION)
    r.check("(a) быстрый ответ: статус 200", status == 200, f"{status} {data}")
    r.check("(a) быстрый ответ: готовый текст из базы", data.get("answer") == QUICK_EXPECTED, repr(data.get("answer")))
    r.check("(a) быстрый ответ: route_used = quick_answer", data.get("route_used") == "quick_answer",
            repr(data.get("route_used")))
    r.check("(a) быстрый ответ: без источников", data.get("sources") == [], repr(data.get("sources")))
    r.check("(a) быстрый ответ: LLM-заглушка не вызывалась",
            len(jsonl(LLM_UP, "/tmp/llm_requests.jsonl")) == llm_before)

    # (b) вопрос по документу (с историей — чтобы прошло и переписывание вопроса)
    history = [{"role": "user", "content": "Привет"}, {"role": "assistant", "content": "Здравствуйте! Чем помочь?"}]
    before = len(jsonl(LLM_UP, "/tmp/llm_requests.jsonl"))
    status, data, _ = generate(base, DOC_QUESTION, history)
    calls = jsonl(LLM_UP, "/tmp/llm_requests.jsonl")[before:]
    kinds = [c["kind"] for c in calls]
    r.check("(b) документ: статус 200", status == 200, f"{status} {data}")
    r.check("(b) документ: route_used = hybrid", data.get("route_used") == "hybrid", repr(data.get("route_used")))
    r.check("(b) документ: ответ модели пришёл через прокси (название источника в ответе)",
            DOC_TITLE in (data.get("answer") or ""), repr(data.get("answer")))
    titles = [s.get("title") for s in data.get("sources") or []]
    r.check("(b) документ: источник — нужный документ", titles == [DOC_TITLE], repr(titles))
    r.check("(b) документ: LLM вызвана для переписывания, реранка и ответа",
            kinds == ["rewrite", "rerank", "answer"], repr(kinds))
    r.check("(b) прокси подставил модель роутера из config.json",
            bool(calls) and all(c["model"] == ROUTER_MODEL for c in calls), repr([c["model"] for c in calls]))
    r.check("(b) Authorization upstream — ключ прокси, не клиента",
            bool(calls) and all(c["authorization"] == f"Bearer {ROUTER_KEY}" for c in calls),
            repr([c["authorization"] for c in calls]))
    r.check("(b) путь upstream — /v1/chat/completions",
            bool(calls) and all(c["path"] == "/v1/chat/completions" for c in calls), repr([c["path"] for c in calls]))
    answer_calls = [c for c in calls if c["kind"] == "answer"]
    rerank_calls = [c for c in calls if c["kind"] == "rerank"]
    r.check("(b) ответ запрошен потоком (stream)", bool(answer_calls) and answer_calls[0]["stream"])
    r.check("(b) реранк получил чанки документа",
            bool(rerank_calls) and DOCS[0]["chunks"][0][1][:40] in rerank_calls[0]["user"])
    r.check("(b) ссылка с http:// попала в промпт ответа",
            bool(answer_calls) and HTTP_LINK in answer_calls[0]["user"])
    r.check("(b) sources[].score = оценка реранка (0.9 у первого попадания)",
            bool(data.get("sources")) and data["sources"][0].get("score") == 0.9,
            repr(data.get("sources")))

    # (d) вопрос не по теме — промпт с guardrails
    before = len(jsonl(LLM_UP, "/tmp/llm_requests.jsonl"))
    status, data, _ = generate(base, OFFTOPIC_QUESTION)
    calls = jsonl(LLM_UP, "/tmp/llm_requests.jsonl")[before:]
    answer_calls = [c for c in calls if c["kind"] == "answer"]
    r.check("(d) не по теме: статус 200, route_used = hybrid",
            status == 200 and data.get("route_used") == "hybrid", f"{status} {data}")
    r.check("(d) не по теме: системный промпт ответа содержит guardrails",
            bool(answer_calls) and all(m in answer_calls[0]["system"] for m in GUARDRAIL_MARKERS))
    r.check("(d) не по теме: вопрос пользователя в промпте ответа",
            bool(answer_calls) and question_in(answer_calls[0]["user"], "Вопрос пользователя:\n", "\n\nОтвет:")
            == OFFTOPIC_QUESTION)
    r.check("(d) не по теме: возвращён ответ заглушки",
            bool(answer_calls) and data.get("answer") == answer_calls[0]["content"], repr(data.get("answer")))

    # (f) очень длинный вопрос обрезается, а не отклоняется
    long_question = (DOC_QUESTION + " ") * (20000 // (len(DOC_QUESTION) + 1) + 1)
    long_question = long_question[:20000]
    before = len(jsonl(LLM_UP, "/tmp/llm_requests.jsonl"))
    emb_before = len(jsonl(EMB, "/tmp/embed_requests.jsonl"))
    status, data, _ = generate(base, long_question)
    calls = jsonl(LLM_UP, "/tmp/llm_requests.jsonl")[before:]
    r.check("(f) 20000 символов: статус 200 (не 422)", status == 200 and len(long_question) == 20000,
            f"{status} {str(data)[:300]}")
    rerank_q = [question_in(c["user"], "Вопрос:\n", "\n\nФрагменты:") for c in calls if c["kind"] == "rerank"]
    answer_q = [question_in(c["user"], "Вопрос пользователя:\n", "\n\nОтвет:") for c in calls if c["kind"] == "answer"]
    r.check("(f) реранк получил вопрос не длиннее 4000",
            bool(rerank_q) and all(0 < len(q) <= MAX_QUESTION_CHARS for q in rerank_q), repr([len(q) for q in rerank_q]))
    r.check("(f) промпт ответа содержит вопрос не длиннее 4000",
            bool(answer_q) and all(0 < len(q) <= MAX_QUESTION_CHARS for q in answer_q), repr([len(q) for q in answer_q]))
    emb_lengths = [n for e in jsonl(EMB, "/tmp/embed_requests.jsonl")[emb_before:] for n in e["lengths"]]
    r.check("(f) в embedding-svc ушёл обрезанный вопрос",
            bool(emb_lengths) and max(emb_lengths) <= MAX_QUESTION_CHARS, repr(emb_lengths))

    # (c) все вопросы — kind=query
    embeds = jsonl(EMB, "/tmp/embed_requests.jsonl")
    r.check("(c) вопросы уходят в embedding-svc с kind=query",
            len(embeds) >= 6 and {e["kind"] for e in embeds} == {"query"},
            repr([e["kind"] for e in embeds]))

    # (e) upstream LLM недоступен
    docker("rm", "-f", LLM_UP)
    status, data, elapsed = generate(base, DOC_QUESTION, timeout=60)
    r.check(f"(e) upstream недоступен: 502 за {elapsed:.1f} с (не дольше 20 с)",
            status == 502 and elapsed < 20, f"{status} {data}")


def cleanup(image_built_here: bool) -> None:
    for container in (GRS, PROXY, LLM_UP, EMB, DB):
        subprocess.run(["docker", "rm", "-f", "-v", container], capture_output=True)
    subprocess.run(["docker", "volume", "rm", "-f", PROXY_VOLUME], capture_output=True)
    subprocess.run(["docker", "network", "rm", NET], capture_output=True)
    if image_built_here and not KEEP_IMAGE:
        subprocess.run(["docker", "rmi", IMAGE], capture_output=True)


def leftovers() -> list[str]:
    found = []
    for args in (["ps", "-a", "--format", "{{.Names}}"], ["network", "ls", "--format", "{{.Name}}"],
                 ["volume", "ls", "--format", "{{.Name}}"]):
        found += [name for name in docker(*args, check=False).split() if name.startswith(P)]
    return found


def main() -> int:
    # SIGTERM — как Ctrl+C: finally ниже всё равно уберёт контейнеры.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    r = Results()
    image_built_here = not image_exists(IMAGE)
    started = time.monotonic()
    try:
        print(f"Сборка образа {IMAGE} из services/graph-rag-svc…")
        docker("build", "-q", "-t", IMAGE, str(ROOT / "services/graph-rag-svc"), timeout=1800)
        docker("network", "create", NET)
        start_database()
        start_stubs()
        start_proxy()
        base = start_graph_rag()
        r.check("стенд поднят: graph-rag-svc прошёл стартовые проверки и загрузил индекс", True)
        run_checks(base, r)
    except KeyboardInterrupt:
        r.check("прервано", False)
    except Exception as exc:
        r.check("стенд", False, str(exc))
        if subprocess.run(["docker", "inspect", GRS], capture_output=True).returncode == 0:
            print(logs_tail(GRS))
    finally:
        cleanup(image_built_here)
    rest = leftovers()
    r.check("очистка: не осталось контейнеров, сетей и томов теста", not rest, repr(rest))
    print(f"Итого: {r.passed} пройдено, {r.failed} провалено за {time.monotonic() - started:.0f} с")
    return 0 if r.failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
