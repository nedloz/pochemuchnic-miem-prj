import requests
import random
import string
import time

BASE_URL = "http://localhost/api"
# Используем Session, чтобы requests автоматически сохранял куки (наш HttpOnly refresh_token)
session = requests.Session()

# Генерируем уникальный email для каждого запуска теста
rnd = ''.join(random.choices(string.ascii_lowercase + string.digits, k=5))
EMAIL = f"student_{rnd}@university.edu"
# EMAIL = f"test@test.com"
PASSWORD = "123456"
NEW_PASSWORD = "1234567"
# EMAIL = f"test1@test.com"
# PASSWORD = "1234567"
# NEW_PASSWORD = "12345678"

def print_step(step_name):
    print(f"\n[{step_name.upper()}] {'-'*40}")

def run_tests():
    print(f"🚀 Запускаем интеграционный тест для: {EMAIL}")

    # ==========================================
    # 1. РЕГИСТРАЦИЯ
    # ==========================================
    print_step("1. Регистрация (/auth/register)")
    resp = session.post(f"{BASE_URL}/auth/register", json={
        "email": EMAIL,
        "password": PASSWORD
    })
    assert resp.status_code == 201, f"Ошибка регистрации: {resp.text}"
    print("✅ Пользователь успешно создан.")
    
    # # ==========================================
    # # 2. ВЕРИФИКАЦИЯ ПОЧТЫ
    # # ==========================================
    print_step("2. Верификация почты")
    print("⚠️ Посмотри в терминал, где запущен FastAPI сервер!")
    print("Там должна быть строка: DEBUG EMAIL LINK: /verify-email?token=ТВОЙ_ТОКЕН")
    verify_token = input("DqSbGRrKZA8M_MYxHIjADAAkoIBxJR1m72u6CEvUPv0").strip()
    
    resp = session.get(f"{BASE_URL}/auth/verify-email", params={"token": verify_token})
    assert resp.status_code == 200, f"Ошибка верификации: {resp.text}"
    print("✅ Почта подтверждена.")

    # ==========================================
    # 3. ЛОГИН
    # ==========================================
    print_step("3. Вход (/auth/login)")
    resp = session.post(f"{BASE_URL}/auth/login", json={
        "email": EMAIL,
        "password": PASSWORD
    })
    assert resp.status_code == 200, f"Ошибка логина: {resp.text}"
    data = resp.json()
    access_token = data["access_token"]
    print("✅ Логин успешен. Access Token получен.")
    print(data)
    print(f"🍪 Куки в сессии (Refresh Token): {session.cookies.get_dict()}")

    headers = {"Authorization": f"Bearer {access_token}"}
    # headers = {"Authorization": f"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIyZjNlMDE3MS1hOTgyLTQ0NDItOTM4ZS1mMWMwZTAzNmZiNjkiLCJyb2xlIjoic3R1ZGVudCIsImV4cCI6MTc3Mjc5Mjg2MX0.USdEishKFJUOSmcR8Dv1f-JQHIqsueZaQSfky51gZdk"}

    # ==========================================
    # 4. ПОЛУЧЕНИЕ И ОБНОВЛЕНИЕ ПРОФИЛЯ
    # ==========================================
    print_step("4. Работа с профилем (/users/me)")
    resp = session.get(f"{BASE_URL}/users/me", headers=headers)
    assert resp.status_code == 200, f"Ошибка профиля: {resp.text}"
    print("✅ Пустой профиль получен:", resp.json())

    resp = session.patch(f"{BASE_URL}/users/me", headers=headers, json={
        "first_name": "Иван",
        "last_name": "Иванов",
        "year": 2,
        "group_name": "CS-202"
    })
    assert resp.status_code == 200, f"Ошибка обновления профиля: {resp.text}"
    print("✅ Профиль обновлен:", resp.json())

    # ==========================================
    # 5. ПРОВЕРКА ВАЛИДАЦИИ ДЛЯ NGINX
    # ==========================================
    # print_step("5. NGINX Validate (/auth/validate)")
    # resp = session.get(f"{BASE_URL}/auth/validate", headers=headers)
    # assert resp.status_code == 200, f"Ошибка валидации NGINX: {resp.text}"
    # print("✅ Валидация успешна. Заголовки для NGINX:")
    # print(f"   X-User-Id: {resp.headers.get('X-User-Id')}")
    # print(f"   X-User-Role: {resp.headers.get('X-User-Role')}")

    # ==========================================
    # 6. REFRESH TOKEN
    # ==========================================
    print_step("6. Обновление токенов (/auth/refresh)")
    # Ждем пару секунд, чтобы время выдачи токенов немного отличалось
    time.sleep(1) 
    # Запрос идет БЕЗ заголовка Authorization, но С куками (requests делает это сам)
    resp = session.post(f"{BASE_URL}/auth/refresh")
    assert resp.status_code == 200, f"Ошибка Refresh: {resp.text}"
    new_access_token = resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {new_access_token}"}
    print("✅ Токены успешно обновлены (ротация прошла).")

    # ==========================================
    # 7. ВОССТАНОВЛЕНИЕ ПАРОЛЯ
    # ==========================================
    print_step("7. Запрос сброса пароля (/auth/forgot-password)")
    resp = session.post(f"{BASE_URL}/auth/forgot-password", json={"email": EMAIL})
    assert resp.status_code == 200, f"Ошибка запроса сброса: {resp.text}"
    print("⚠️ Посмотри в терминал сервера! Скопируй токен сброса пароля.")
    reset_token = input("Введи токен сброса (reset token) сюда: ").strip()

    resp = session.post(f"{BASE_URL}/auth/update-password", json={
        "token": reset_token,
        "new_password": NEW_PASSWORD
    })
    assert resp.status_code == 200, f"Ошибка установки пароля: {resp.text}"
    print("✅ Пароль успешно изменен.")

    # Проверяем логин со старым и новым паролем
    resp = session.post(f"{BASE_URL}/auth/login", json={"email": EMAIL, "password": PASSWORD})
    assert resp.status_code == 401, "ОШИБКА: Смогли войти со старым паролем!"
    
    resp = session.post(f"{BASE_URL}/auth/login", json={"email": EMAIL, "password": NEW_PASSWORD})
    assert resp.status_code == 200, "Ошибка входа с новым паролем."
    print("✅ Успешный вход с новым паролем.")

    # ==========================================
    # 8. LOGOUT
    # ==========================================
    print_step("8. Выход (/auth/logout)")
    resp = session.post(f"{BASE_URL}/auth/logout")
    assert resp.status_code == 200, f"Ошибка Logout: {resp.text}"
    
    # Пробуем сделать refresh после логаута (должна быть ошибка)
    resp = session.post(f"{BASE_URL}/auth/refresh")
    assert resp.status_code == 401, "ОШИБКА: Refresh сработал после логаута!"
    print("✅ Успешный выход. Старые куки больше не работают.")

    print("\n🎉 ВСЕ ТЕСТЫ УСПЕШНО ПРОЙДЕНЫ! Микросервис работает как часы.")

if __name__ == "__main__":
    try:
        run_tests()
    except AssertionError as e:
        print(f"\n❌ ТЕСТ ПРОВАЛЕН: {e}")
    except requests.exceptions.ConnectionError:
        print("\n❌ ОШИБКА: Не удалось подключиться к серверу. Убедись, что uvicorn запущен на порту 8000.")
