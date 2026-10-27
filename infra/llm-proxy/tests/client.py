"""Клиент для proxy_e2e.sh: шлёт запрос в llm-proxy и печатает результат строками key=value.

    client.py chat URL            тело как у graph-rag-svc (model "default") и чужой Authorization;
                                  печатает, что увидела заглушка upstream
    client.py stream URL          тот же запрос со "stream": true; печатает число событий SSE,
                                  время до первого и до конца ответа
    client.py status METHOD URL   только код ответа (тело — пустой JSON-объект или BODY из env)
"""

import http.client
import json
import os
import sys
import time
import urllib.parse

# Маркер тела: proxy_e2e.sh проверяет, что его нет в логах прокси.
BODY = {
    "model": "default",
    "messages": [
        {"role": "system", "content": "Ты помощник первокурсника"},
        {"role": "user", "content": "маркер-тела-7f3a: где расписание?"},
    ],
    "temperature": 0.3,
    "max_tokens": 77,
    "stream": False,
}


def request(method, url, body, headers=None):
    u = urllib.parse.urlsplit(url)
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=15)
    data = body.encode("utf-8") if isinstance(body, str) else body
    conn.request(method, u.path, body=data, headers=headers or {})
    return conn.getresponse()


def chat(url):
    resp = request("POST", url, json.dumps(BODY, ensure_ascii=False),
                   {"Content-Type": "application/json", "Authorization": "Bearer client"})
    print(f"status={resp.status}")
    raw = resp.read().decode("utf-8")
    if resp.status != 200:
        return
    seen = json.loads(raw)
    sent = seen["body"]
    print(f"path={seen['path']}")
    print(f"host={seen['host']}")
    print(f"model={sent.get('model')}")
    print(f"auth={seen['headers'].get('authorization', '-')}")
    rest_sent = {k: v for k, v in BODY.items() if k != "model"}
    rest_seen = {k: v for k, v in sent.items() if k != "model"}
    print("rest=" + ("same" if rest_sent == rest_seen else "differs:" + json.dumps(rest_seen, ensure_ascii=False)))


def stream(url):
    body = dict(BODY, stream=True)
    t0 = time.monotonic()
    resp = request("POST", url, json.dumps(body, ensure_ascii=False), {"Content-Type": "application/json"})
    print(f"status={resp.status}")
    events, first = 0, None
    while True:
        line = resp.readline()
        if not line:
            break
        if line.startswith(b"data:"):
            events += 1
            if first is None:
                first = time.monotonic() - t0
    total = time.monotonic() - t0
    print(f"events={events}")
    print(f"first={first if first is not None else -1:.2f}")
    print(f"total={total:.2f}")


def status(method, url):
    resp = request(method, url, os.environ.get("BODY", "{}"), {"Content-Type": "application/json"})
    resp.read()
    print(f"status={resp.status}")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "chat":
        chat(sys.argv[2])
    elif cmd == "stream":
        stream(sys.argv[2])
    elif cmd == "status":
        status(sys.argv[2], sys.argv[3])
    else:
        sys.exit(f"неизвестная команда: {cmd}")
