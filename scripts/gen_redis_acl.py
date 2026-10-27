#!/usr/bin/env python3
"""Учётные записи Redis: по записи на сервис, каждая видит только свои ключи.

Redis 7 не умеет сопоставлять CN клиентского сертификата с ACL-пользователем, поэтому доступ
двойной: сертификат (прокси infra/mtls/redis.conf пускает только auth-svc и chat-svc) и пароль
ACL-пользователя, который ограничивает команды и префиксы ключей:

    auth-svc   ~auth:*
    chat-svc   ~ws:*  ~chat:*

Пользователь default выключен. Запускается один раз, повторный запуск ничего не меняет:

    python3 scripts/gen_redis_acl.py             # создать, если ещё нет
    python3 scripts/gen_redis_acl.py --rotate    # перевыпустить пароли

Результат: secrets/redis/users.acl (в .gitignore; в нём только SHA-256 паролей) и переменные
REDIS_AUTH_PASSWORD, REDIS_CHAT_PASSWORD, REDIS_PROMETHEUS_PASSWORD в .env. После ротации пересоздать redis и сервисы:
    docker compose up -d --no-deps redis redis-mtls auth-svc chat-svc
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import secrets
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
# пути переопределяются только в тестах, чтобы не трогать настоящие secrets/ и .env
ACL = Path(os.environ.get("REDIS_ACL_FILE") or ROOT / "secrets" / "redis" / "users.acl")
ENV = Path(os.environ.get("REDIS_ENV_FILE") or ROOT / ".env")

# сервис -> (переменная с паролем, шаблоны ключей)
USERS = {
    "auth-svc": ("REDIS_AUTH_PASSWORD", ["auth:*"]),
    "chat-svc": ("REDIS_CHAT_PASSWORD", ["ws:*", "chat:*"]),
}

# Пользователь redis_exporter (docker-compose.observability.yml): ключей не видит, только
# служебная статистика.
EXPORTER_USER = ("prometheus", "REDIS_PROMETHEUS_PASSWORD")
EXPORTER_RULES = "resetkeys resetchannels -@all +ping +info +config|get +dbsize +slowlog|get +latency|latest +client|list"


def read_env() -> dict[str, str]:
    values: dict[str, str] = {}
    if ENV.exists():
        for line in ENV.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
            if m:
                values[m.group(1)] = m.group(2)
    return values


def set_env(name: str, value: str) -> None:
    text = ENV.read_text(encoding="utf-8") if ENV.exists() else ""
    line = f"{name}={value}"
    if re.search(rf"^{name}=.*$", text, re.M):
        text = re.sub(rf"^{name}=.*$", line, text, flags=re.M)
    else:
        text = text + ("" if text.endswith("\n") or not text else "\n") + line + "\n"
    ENV.write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rotate", action="store_true", help="перевыпустить пароли")
    args = parser.parse_args()

    env = read_env()
    lines = [
        # В aclfile комментарии не допускаются: Redis отказывается стартовать.
        "user default off",
        # Для healthcheck: только PING, ключей не видит.
        "user health on nopass resetkeys resetchannels -@all +ping",
    ]
    created = []
    for service, (var, patterns) in USERS.items():
        password = env.get(var, "")
        if args.rotate or len(password) < 32:
            password = secrets.token_urlsafe(32)
            set_env(var, password)
            created.append(service)
        digest = hashlib.sha256(password.encode()).hexdigest()
        keys = " ".join(f"~{p}" for p in patterns)
        lines.append(f"user {service} on #{digest} {keys} resetchannels +@all -@admin -@dangerous")

    name, var = EXPORTER_USER
    password = env.get(var, "")
    if args.rotate or len(password) < 32:
        password = secrets.token_urlsafe(32)
        set_env(var, password)
        created.append(name)
    lines.append(f"user {name} on #{hashlib.sha256(password.encode()).hexdigest()} {EXPORTER_RULES}")

    ACL.parent.mkdir(parents=True, exist_ok=True)
    ACL.write_text("\n".join(lines) + "\n", encoding="utf-8")
    ACL.chmod(0o644)  # читает redis в контейнере; хэши, не пароли
    print(f"{ACL}: готово" + (f"; новые пароли: {', '.join(created)}" if created else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
