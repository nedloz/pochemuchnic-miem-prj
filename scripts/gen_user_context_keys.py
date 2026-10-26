#!/usr/bin/env python3
"""Ключи подписи пользовательского контекста (services/auth-svc/app/user_context.py).

auth-svc подписывает контекст пользователя, который nginx пробрасывает сервисам вместо голых
заголовков X-User-Id / X-User-Role. Для каждого сервиса-получателя ключ свой, производный от
мастер-ключа: K(aud) = HMAC-SHA256(master, "user-context:v1:" + aud). Мастер знает только
auth-svc; получатель знает свой производный ключ и подделать токен для другого сервиса не может.

    python3 scripts/gen_user_context_keys.py             # создать, если ключей ещё нет
    python3 scripts/gen_user_context_keys.py --rotate    # добавить новый ключ, старые оставить

Результат в secrets/user-context/ (в .gitignore):
    master.key       мастер-ключ (auth-svc)
    <сервис>.key     производный ключ сервиса (auth-svc, chat-svc, library-svc, db-svc)

В файле по ключу в строке (hex); первый — текущий, им подписывают; остальные принимаются при
проверке. Ротация без простоя:
    1. --rotate: в каждом файле новый ключ встаёт первым, прежний остаётся вторым;
    2. пересоздать сервисы (docker compose up -d --no-deps auth-svc chat-svc library-svc db-svc):
       auth-svc подписывает новым ключом, получатели принимают оба;
    3. через несколько минут (токен живёт минуту) --prune убирает прежние ключи.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import os
import secrets
import stat
import sys
from pathlib import Path

AUDIENCES = ["auth-svc", "chat-svc", "library-svc", "db-svc"]
LABEL = "user-context:v1:"
OUT_DIR = Path(__file__).resolve().parent.parent / "secrets" / "user-context"


def derive(master: bytes, audience: str) -> bytes:
    return hmac.new(master, (LABEL + audience).encode(), hashlib.sha256).digest()


def read_keys(path: Path) -> list[bytes]:
    if not path.is_file():
        return []
    return [
        bytes.fromhex(line.strip())
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.startswith("#")
    ]


def write_keys(path: Path, keys: list[bytes], comment: str) -> None:
    text = f"# {comment}\n" + "".join(k.hex() + "\n" for k in keys)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rotate", action="store_true", help="добавить новый ключ первым, прежние оставить")
    parser.add_argument("--prune", action="store_true", help="оставить только текущий ключ")
    args = parser.parse_args()

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(OUT_DIR, 0o700)
    master_path = OUT_DIR / "master.key"
    masters = read_keys(master_path)

    if args.prune:
        masters = masters[:1]
    elif args.rotate or not masters:
        masters = [secrets.token_bytes(32)] + masters
        # Не больше двух: текущий и предыдущий. Третий был бы уже мёртвым грузом.
        masters = masters[:2]
    else:
        print(f"Ключи уже есть ({OUT_DIR}); для ротации: --rotate")
        return 0

    write_keys(master_path, masters, "мастер-ключ подписи контекста пользователя; только auth-svc")
    for aud in AUDIENCES:
        write_keys(
            OUT_DIR / f"{aud}.key",
            [derive(m, aud) for m in masters],
            f"производный ключ проверки контекста пользователя для {aud}",
        )
    print(f"Ключей в файлах: {len(masters)} ({OUT_DIR}). Пересоздайте сервисы, чтобы они подхватили изменения.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
