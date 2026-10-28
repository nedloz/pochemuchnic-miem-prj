"""Заглушка upstream LLM (роутер) за настоящим llm-proxy для сквозной проверки.

POST /v1/chat/completions, OpenAI-совместимый ответ. Что вернуть, решает системный промпт:
- реранк («Ты переранжируешь фрагменты…») — JSON {"ranked": [...]}: первый кандидат из сообщения
  получает 0.9, остальные 0.1, в исходном порядке;
- переписывание вопроса («Ты — помощник, который переписывает…») — тот же вопрос;
- остальное (финальный ответ) — фиксированный ответ с названием первого источника из блока
  «Материалы», потоком SSE (close-delimited) или целиком.
Каждый запрос пишется строкой JSON в /tmp/llm_requests.jsonl: путь, model, Authorization, stream,
вид вызова, system, user и выданный ответ.
"""

import json
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = "/tmp/llm_requests.jsonl"
RERANK_PREFIX = "Ты переранжируешь фрагменты"
REWRITE_PREFIX = "Ты — помощник, который переписывает"


def answer_text(user: str) -> str:
    match = re.search(r"^Источник: (.+)$", user, re.M)
    if match:
        return f"Ответ-заглушка по материалам «{match.group(1).strip()}»."
    return "Ответ-заглушка: материалы не найдены."


def rerank_text(user: str) -> str:
    _, _, fragments = user.partition("Фрагменты:\n")
    items = json.loads(fragments)
    ranked = [{"id": item["id"], "score": 0.9 if pos == 0 else 0.1} for pos, item in enumerate(items)]
    return json.dumps({"ranked": ranked}, ensure_ascii=False)


def rewrite_text(user: str) -> str:
    match = re.search(r"Текущий вопрос: (.*)\n\nПолный вопрос:", user, re.S)
    return match.group(1) if match else user


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        body = json.loads(raw or b"{}")
        messages = body.get("messages") or []
        system = next((m.get("content", "") for m in messages if m.get("role") == "system"), "")
        user = next((m.get("content", "") for m in reversed(messages) if m.get("role") == "user"), "")

        if system.startswith(RERANK_PREFIX):
            kind, content = "rerank", rerank_text(user)
        elif system.startswith(REWRITE_PREFIX):
            kind, content = "rewrite", rewrite_text(user)
        else:
            kind, content = "answer", answer_text(user)

        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "path": self.path,
                "model": body.get("model"),
                "authorization": self.headers.get("Authorization"),
                "stream": bool(body.get("stream")),
                "kind": kind,
                "system": system,
                "user": user,
                "content": content,
            }, ensure_ascii=False) + "\n")

        model = body.get("model") or "stub"
        created = int(time.time())
        usage = {"prompt_tokens": 11, "completion_tokens": 7, "total_tokens": 18}
        if not body.get("stream"):
            payload = json.dumps({
                "id": "stub-1", "object": "chat.completion", "created": created, "model": model,
                "choices": [{"index": 0, "message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
                "usage": usage,
            }, ensure_ascii=False).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        # Поток без Content-Length и chunked: конец ответа — закрытие соединения (HTTP/1.0).
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def event(obj) -> None:
            self.wfile.write(b"data: " + json.dumps(obj, ensure_ascii=False).encode() + b"\n\n")
            self.wfile.flush()

        third = max(1, len(content) // 3)
        pieces = [content[:third], content[third:2 * third], content[2 * third:]]
        base = {"id": "stub-1", "object": "chat.completion.chunk", "created": created, "model": model}
        for piece in pieces:
            if piece:
                event({**base, "choices": [{"index": 0, "delta": {"content": piece}, "finish_reason": None}]})
        event({**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
        event({**base, "choices": [], "usage": usage})
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 9000), Handler).serve_forever()
