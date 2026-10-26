"""Заглушка chat-svc для gateway_e2e.sh: WebSocket + обычный HTTP на одном порту, только localhost.

WebSocket: после рукопожатия сразу присылает «connected» с проверенным пользователем (настоящий
модуль user_context), как это делает chat-svc. Обычный GET отвечает как echo-заглушка.
Запускается в образе chat-svc (там есть websockets).
"""

from __future__ import annotations

import asyncio
import json
import os
import sys

sys.path.insert(0, "/srv")
import user_context  # noqa: E402
from websockets.datastructures import Headers  # noqa: E402
from websockets.http11 import Response  # noqa: E402
from websockets.asyncio.server import serve  # noqa: E402


def verified(headers) -> dict:
    try:
        ctx = user_context.verify_from_env(headers.get(user_context.HEADER))
        return {"user_id": ctx.user_id, "role": ctx.role, "aud": ctx.audience}
    except user_context.UserContextError as exc:
        return {"error": str(exc)}


async def handler(ws):
    headers = ws.request.headers
    await ws.send(json.dumps({
        "type": "connected", "path": ws.request.path, "verified": verified(headers),
        "caller": headers.get("X-Caller-Identity"),
    }))
    await ws.wait_closed()


def process_request(connection, request):
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return None
    body = json.dumps({
        "service": "chat-svc", "path": request.path,
        "headers": {k.lower(): v for k, v in request.headers.items()},
        "verified": verified(request.headers), "caller": request.headers.get("X-Caller-Identity"),
    }).encode()
    return Response(200, "OK", Headers([("Content-Type", "application/json"), ("Content-Length", str(len(body)))]), body)


async def main():
    async with serve(handler, "127.0.0.1", 8000, process_request=process_request):
        await asyncio.Future()


asyncio.run(main())
