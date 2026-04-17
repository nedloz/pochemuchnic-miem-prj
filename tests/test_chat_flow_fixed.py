import json
import os
import random
import string
import sys
import time
from typing import Any
from uuid import uuid4

import requests
from websocket import WebSocketTimeoutException, create_connection


BASE_URL = os.getenv("CHAT_TEST_BASE_URL", "http://localhost/api").rstrip("/")
WS_URL = os.getenv("CHAT_TEST_WS_URL", "ws://localhost/api/chat/ws/chat")
VERIFY_TOKEN = os.getenv("CHAT_TEST_VERIFY_TOKEN")
TEST_TIMEOUT = float(os.getenv("CHAT_TEST_TIMEOUT", "20"))
STREAM_TIMEOUT = float(os.getenv("CHAT_TEST_STREAM_TIMEOUT", "180"))
RUN_HEALTHCHECK = os.getenv("CHAT_TEST_RUN_HEALTHCHECK", "false").lower() in {"1", "true", "yes"}

session = requests.Session()

RND = "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
TEST_EMAIL = os.getenv("CHAT_TEST_EMAIL", f"chat_test_{RND}@example.com")
TEST_PASSWORD = os.getenv("CHAT_TEST_PASSWORD", "12345678")


ALLOWED_INTERMEDIATE_EVENTS = {
    "question_accepted",
    "generation_started",
    "status",
    "info",
}

COMPLETION_EVENTS = {"message_completed", "completed"}
ERROR_EVENTS = {"error", "message_error"}
FEEDBACK_ACK_EVENTS = {"feedback_saved", "feedback_set", "ok"}


def print_step(name: str) -> None:
    print(f"\n[{name}] {'-' * 50}")


def assert_status(resp: requests.Response, expected: int | tuple[int, ...], context: str) -> None:
    if isinstance(expected, int):
        expected_values = (expected,)
    else:
        expected_values = expected

    assert resp.status_code in expected_values, (
        f"{context}: ожидали статус {expected_values}, получили {resp.status_code}\n"
        f"URL: {resp.request.method} {resp.request.url}\n"
        f"Body: {resp.text}"
    )


def check_health() -> None:
    print_step("HEALTH")
    resp = session.get(f"{BASE_URL}/chat/healthz", timeout=TEST_TIMEOUT)
    assert_status(resp, 200, "Проверка healthz chat-svc")
    print("✅ chat-svc healthz ok")


def register_user() -> dict[str, Any]:
    print_step("REGISTER")
    payload = {
        "email": TEST_EMAIL,
        "password": TEST_PASSWORD,
    }
    resp = session.post(f"{BASE_URL}/auth/register", json=payload, timeout=TEST_TIMEOUT)

    if resp.status_code in (200, 201):
        data = resp.json() if resp.text else {}
        print(f"✅ Пользователь зарегистрирован: {TEST_EMAIL}")
        return data

    if resp.status_code in (400, 409, 422):
        print(f"ℹ️ Пользователь уже существует или регистрация отклонена как дубль: {TEST_EMAIL}")
        try:
            return resp.json()
        except Exception:
            return {"detail": resp.text}

    raise AssertionError(
        f"Ошибка регистрации: статус={resp.status_code}, body={resp.text}"
    )


def verify_email_if_needed() -> None:
    print_step("VERIFY EMAIL")

    verify_token = VERIFY_TOKEN
    if verify_token:
        print("ℹ️ Использую токен из CHAT_TEST_VERIFY_TOKEN.")
    else:
        if not sys.stdin.isatty():
            raise AssertionError(
                "Для этапа verify-email нужен ввод токена с консоли, но stdin не интерактивный. "
                "Запусти тест в терминале или передай CHAT_TEST_VERIFY_TOKEN через env."
            )

        print("⏸️ Тест остановлен на этапе подтверждения email.")
        print("Скопируй токен из письма/логов и вставь его в консоль ниже.")
        verify_token = input("Введи токен подтверждения email: ").strip()

    if not verify_token:
        raise AssertionError("Токен подтверждения email пустой.")

    resp = session.get(
        f"{BASE_URL}/auth/verify-email",
        params={"token": verify_token},
        timeout=TEST_TIMEOUT,
    )

    if resp.status_code in (200, 204):
        print("✅ Почта подтверждена.")
        return

    if resp.status_code in (400, 404, 409, 422):
        print(f"ℹ️ verify-email вернул {resp.status_code}: {resp.text}")
        return

    raise AssertionError(
        f"Ошибка verify-email: статус={resp.status_code}, body={resp.text}"
    )


def get_access_token() -> str:
    print_step("LOGIN")
    payload = {
        "email": TEST_EMAIL,
        "password": TEST_PASSWORD,
    }
    resp = session.post(f"{BASE_URL}/auth/login", json=payload, timeout=TEST_TIMEOUT)
    assert_status(resp, 200, "Логин пользователя")

    data = resp.json()
    access_token = data.get("access_token")
    assert access_token, f"В ответе логина нет access_token: {data}"

    print("✅ Access token получен.")
    return access_token


def get_profile(access_token: str) -> dict[str, Any]:
    print_step("PROFILE")
    resp = session.get(
        f"{BASE_URL}/users/me",
        headers={"Authorization": f"Bearer {access_token}"},
        timeout=TEST_TIMEOUT,
    )
    assert_status(resp, 200, "Получение профиля пользователя")

    profile = resp.json()
    print(f"✅ Профиль получен: {profile}")
    return profile


def register_and_login() -> tuple[str, dict[str, Any]]:
    register_user()
    verify_email_if_needed()
    access_token = get_access_token()
    profile = get_profile(access_token)
    return access_token, profile


def ws_connect(access_token: str) -> tuple[Any, dict[str, Any]]:
    print_step("WS CONNECT")
    ws = create_connection(
        WS_URL,
        header=[f"Authorization: Bearer {access_token}"],
        timeout=TEST_TIMEOUT,
    )

    raw = ws.recv()
    print(f"connected raw: {raw}")

    data = json.loads(raw)
    assert data.get("type") == "connected", f"Ожидали connected, получили: {data}"

    print(f"✅ WebSocket подключен: {data}")
    return ws, data


def send_ws(ws: Any, payload: dict[str, Any]) -> None:
    raw = json.dumps(payload, ensure_ascii=False)
    print(f">>> {raw}")
    ws.send(raw)


def recv_ws(ws: Any, timeout: float = TEST_TIMEOUT) -> dict[str, Any]:
    ws.settimeout(timeout)
    raw = ws.recv()
    print(f"<<< {raw}")
    return json.loads(raw)


def recv_until_type(ws: Any, expected_types: set[str], timeout: float) -> dict[str, Any]:
    deadline = time.time() + timeout
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            raise AssertionError(f"Не дождались событий {sorted(expected_types)} за {timeout} сек.")

        data = recv_ws(ws, timeout=remaining)
        msg_type = data.get("type")

        if msg_type in ERROR_EVENTS:
            raise AssertionError(f"Получено error-событие: {data}")

        if msg_type in expected_types:
            return data

        if msg_type in ALLOWED_INTERMEDIATE_EVENTS:
            continue

        raise AssertionError(f"Неожиданное сообщение: {data}")


def test_ping(ws: Any) -> None:
    print_step("PING")
    send_ws(ws, {"type": "ping"})
    data = recv_ws(ws)
    assert data.get("type") == "pong", f"Ожидали pong, получили: {data}"
    print("✅ ping/pong работает")


def test_initial_history(ws: Any) -> None:
    print_step("INITIAL HISTORY")
    send_ws(
        ws,
        {
            "type": "history_get",
            "limit": 20,
            "before_message_id": None,
        },
    )

    data = recv_until_type(ws, {"history_page"}, timeout=TEST_TIMEOUT)
    assert isinstance(data.get("items"), list), f"Поле items должно быть списком: {data}"

    print(f"✅ История получена, сообщений: {len(data['items'])}")


def test_question_flow(ws: Any) -> tuple[str, str, str]:
    print_step("QUESTION FLOW")

    request_id = str(uuid4())
    question_text = f"Расскажи про правила общежития номер 6"

    send_ws(
        ws,
        {
            "type": "question",
            "request_id": request_id,
            "content": question_text,
        },
    )

    started = recv_until_type(ws, {"message_started"}, timeout=30)
    user_message_id = started.get("user_message_id")
    assistant_message_id = started.get("assistant_message_id")

    assert user_message_id, f"Нет user_message_id в message_started: {started}"
    assert assistant_message_id, f"Нет assistant_message_id в message_started: {started}"

    chunks: list[str] = []
    completed: dict[str, Any] | None = None
    accepted_seen = False
    generation_started_seen = False

    deadline = time.time() + STREAM_TIMEOUT
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            raise AssertionError("Истек таймаут ожидания завершения стрима")

        data = recv_ws(ws, timeout=remaining)
        msg_type = data.get("type")

        if msg_type == "question_accepted":
            accepted_seen = True
            if data.get("request_id") not in (None, request_id):
                raise AssertionError(f"request_id в question_accepted не совпадает: {data}")
            continue

        if msg_type == "generation_started":
            generation_started_seen = True
            if data.get("assistant_message_id") not in (None, assistant_message_id):
                raise AssertionError(f"assistant_message_id в generation_started не совпадает: {data}")
            continue

        if msg_type == "stream_chunk":
            if data.get("assistant_message_id") not in (None, assistant_message_id):
                raise AssertionError(f"assistant_message_id в stream_chunk не совпадает: {data}")
            chunk = data.get("delta") or data.get("content") or data.get("text") or ""
            chunks.append(chunk)
            continue

        if msg_type in COMPLETION_EVENTS:
            completed = data
            break

        if msg_type in ERROR_EVENTS:
            raise AssertionError(f"chat-svc вернул error во время стрима: {data}")

        if msg_type in ALLOWED_INTERMEDIATE_EVENTS:
            continue

        raise AssertionError(f"Неожиданное сообщение во время question flow: {data}")

    full_text = "".join(chunks).strip()
    print(f"✅ Стрим завершён. Длина ответа: {len(full_text)}")
    print(f"assistant_message_id={assistant_message_id}")
    print(f"question_accepted_seen={accepted_seen}, generation_started_seen={generation_started_seen}")

    assert completed is not None, "Не получили событие завершения сообщения"
    assert completed.get("assistant_message_id") in (None, assistant_message_id), (
        f"assistant_message_id в completed не совпадает: {completed}"
    )
    assert full_text or completed.get("content") or completed.get("text"), (
        f"Пустой ответ модели: completed={completed}"
    )

    return request_id, full_text, assistant_message_id


def test_history_after_question(ws: Any, assistant_message_id: str) -> None:
    print_step("HISTORY AFTER QUESTION")

    send_ws(
        ws,
        {
            "type": "history_get",
            "limit": 20,
            "before_message_id": None,
        },
    )

    data = recv_until_type(ws, {"history_page"}, timeout=30)
    items = data.get("items", [])
    assert isinstance(items, list), f"items должен быть list: {data}"

    found = any(str(item.get("id")) == str(assistant_message_id) for item in items)
    assert found, (
        f"Не найден assistant_message_id={assistant_message_id} в истории. "
        f"Последние ids: {[item.get('id') for item in items]}"
    )

    print("✅ Новый ответ присутствует в истории")


def test_feedback(ws: Any, assistant_message_id: str) -> None:
    print_step("FEEDBACK")

    send_ws(
        ws,
        {
            "type": "feedback_set",
            "message_id": assistant_message_id,
            "helpful": 1,
        },
    )

    data = recv_until_type(ws, FEEDBACK_ACK_EVENTS, timeout=TEST_TIMEOUT)
    print(f"✅ Фидбек отправлен: {data.get('type')}")


def run_tests() -> None:
    print(f"🚀 Запускаем интеграционный тест chat-svc через nginx: {WS_URL}")

    if RUN_HEALTHCHECK:
        check_health()

    access_token, profile = register_and_login()
    expected_user_id = str(profile.get("id") or profile.get("user_id"))
    assert expected_user_id and expected_user_id != "None", (
        f"Не удалось извлечь user_id из профиля: {profile}"
    )

    ws = None
    try:
        ws, connected = ws_connect(access_token)

        connected_user_id = connected.get("user_id")
        if connected_user_id is not None:
            assert str(connected_user_id) == expected_user_id, (
                "user_id в событии connected не совпадает с профилем. "
                "Это обычно значит, что nginx не прокинул/подменил X-User-Id как ожидалось. "
                f"connected={connected}, profile_user_id={expected_user_id}"
            )
            print("✅ Nginx корректно пропустил авторизацию и chat-svc получил правильный user_id.")
        else:
            print("ℹ️ В событии connected нет user_id. Пропускаю строгую проверку X-User-Id.")

        test_ping(ws)
        test_initial_history(ws)

        _, _, assistant_message_id = test_question_flow(ws)

        test_history_after_question(ws, assistant_message_id)
        test_feedback(ws, assistant_message_id)

        print("\n🎉 ВСЕ ТЕСТЫ CHAT-SVC УСПЕШНО ПРОЙДЕНЫ!")

    finally:
        if ws is not None:
            try:
                ws.close()
            except Exception:
                pass


if __name__ == "__main__":
    try:
        run_tests()
    except WebSocketTimeoutException as e:
        print(f"\n❌ Таймаут websocket: {e}")
        raise
    except AssertionError as e:
        print(f"\n❌ Тест не пройден: {e}")
        raise
    except Exception as e:
        print(f"\n❌ Неожиданная ошибка: {e}")
        raise
