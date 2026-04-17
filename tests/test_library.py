# test_library_routes.py
# Запуск:
#   python test_library_routes.py
#
# Нужны только стандартные библиотеки Python.
# Тест:
# 1) регистрирует пользователя
# 2) просит ввести verify token в консоли
# 3) логинится и получает access token
# 4) проверяет защищённые роуты без токена
# 5) проверяет защищённые роуты с токеном
# 6) печатает, что именно вернули роуты

import json
import random
import string
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


# =========================
# КОНСТАНТЫ
# =========================
BASE_URL = "http://localhost/api"

REGISTER_PATH = "/auth/register"
VERIFY_EMAIL_PATH = "/auth/verify-email"
LOGIN_PATH = "/auth/login"

TREE_PATH = "/library/tree"
REFRESH_PATH = "/library/refresh"

TIMEOUT = 20

RND = "".join(random.choices(string.ascii_lowercase + string.digits, k=6))
TEST_EMAIL = f"library_test_{RND}@example.com"
TEST_PASSWORD = "12345678"


# =========================
# HTTP UTILS
# =========================
def full_url(path: str, query: dict | None = None) -> str:
    url = BASE_URL.rstrip("/") + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    return url


def pretty(obj) -> str:
    if isinstance(obj, (dict, list)):
        return json.dumps(obj, ensure_ascii=False, indent=2)
    return str(obj)


def try_parse_json(raw: str):
    try:
        return json.loads(raw)
    except Exception:
        return raw


def print_block(title: str) -> None:
    print("\n" + "=" * 70)
    print(title)
    print("=" * 70)


def http_request(method: str, path: str, body: dict | None = None, token: str | None = None, query: dict | None = None):
    url = full_url(path, query)
    data = None
    headers = {
        "Accept": "application/json",
    }

    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"

    if token:
        headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(url=url, data=data, headers=headers, method=method.upper())

    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            parsed = try_parse_json(raw)
            return resp.status, parsed, dict(resp.headers)
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", errors="replace")
        parsed = try_parse_json(raw)
        return e.code, parsed, dict(e.headers)
    except Exception as e:
        raise AssertionError(f"Ошибка запроса {method} {url}: {e}")


def print_response(label: str, status: int, payload) -> None:
    print_block(label)
    print(f"STATUS: {status}")
    print("BODY:")
    print(pretty(payload))


# =========================
# AUTH FLOW
# =========================
def register_user() -> None:
    payload = {
        "email": TEST_EMAIL,
        "password": TEST_PASSWORD,
    }

    status, data, _ = http_request("POST", REGISTER_PATH, body=payload)
    print_response("REGISTER RESPONSE", status, data)

    if status not in (200, 201, 400, 409, 422):
        raise AssertionError(f"Регистрация вернула неожиданный статус {status}")


def verify_email() -> None:
    print_block("VERIFY EMAIL")
    if not sys.stdin.isatty():
        raise AssertionError("Нужен интерактивный запуск, потому что verify token вводится с консоли.")

    token = input("Введи verify token: ").strip()
    if not token:
        raise AssertionError("Пустой verify token.")

    status, data, _ = http_request("GET", VERIFY_EMAIL_PATH, query={"token": token})
    print_response("VERIFY EMAIL RESPONSE", status, data)

    if status not in (200, 204, 400, 404, 409, 422):
        raise AssertionError(f"verify-email вернул неожиданный статус {status}")


def login_and_get_access_token() -> str:
    payload = {
        "email": TEST_EMAIL,
        "password": TEST_PASSWORD,
    }

    status, data, _ = http_request("POST", LOGIN_PATH, body=payload)
    print_response("LOGIN RESPONSE", status, data)

    if status != 200:
        raise AssertionError(f"Логин неуспешен, статус={status}")

    if not isinstance(data, dict):
        raise AssertionError(f"Ожидался JSON-объект от логина, получили: {data}")

    access_token = data.get("access_token")
    if not access_token:
        raise AssertionError(f"В ответе логина нет access_token: {data}")

    print("\nACCESS TOKEN ПОЛУЧЕН")
    return access_token


# =========================
# ROUTE TESTS
# =========================
def test_protected_without_token() -> None:
    status, data, _ = http_request("GET", TREE_PATH)
    print_response("GET TREE WITHOUT TOKEN", status, data)

    if status not in (401, 403, 503):
        raise AssertionError(
            f"GET {TREE_PATH} без токена должен вернуть 401/403 "
            f"(или 503 если авторизация реально не стоит и кэш пуст), получили {status}"
        )

    status, data, _ = http_request("POST", REFRESH_PATH)
    print_response("POST REFRESH WITHOUT TOKEN", status, data)

    if status not in (401, 403, 422):
        raise AssertionError(
            f"POST {REFRESH_PATH} без токена должен вернуть 401/403/422, получили {status}"
        )


def test_tree_with_token(token: str) -> None:
    status, data, _ = http_request("GET", TREE_PATH, token=token)
    print_response("GET TREE WITH TOKEN", status, data)

    if status not in (200, 503):
        raise AssertionError(f"GET {TREE_PATH} с токеном вернул неожиданный статус {status}")


def test_refresh_with_token(token: str) -> None:
    status, data, _ = http_request("POST", REFRESH_PATH, token=token)
    print_response("POST REFRESH WITH TOKEN", status, data)

    if status != 200:
        raise AssertionError(f"POST {REFRESH_PATH} с токеном вернул неожиданный статус {status}")


# =========================
# RUN
# =========================
def run() -> None:
    print_block("START")
    print(f"BASE_URL: {BASE_URL}")
    print(f"TEST_EMAIL: {TEST_EMAIL}")
    print(f"TIME: {int(time.time())}")

    register_user()
    verify_email()
    access_token = login_and_get_access_token()

    test_protected_without_token()
    test_tree_with_token(access_token)
    test_refresh_with_token(access_token)

    print_block("DONE")
    print("Все проверки завершены.")


if __name__ == "__main__":
    try:
        run()
    except AssertionError as e:
        print("\nТЕСТ УПАЛ:")
        print(e)
        raise
    except KeyboardInterrupt:
        print("\nОстановлено пользователем.")
        raise
    except Exception as e:
        print("\nНЕОЖИДАННАЯ ОШИБКА:")
        print(e)
        raise